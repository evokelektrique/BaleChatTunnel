import 'package:bale_client/bale_client.dart';

import 'chunk_transport.dart';
import 'config.dart';
import 'crypto.dart';
import 'logger.dart';
import 'protocol.dart';
import 'saved_messages_transport.dart';
import 'socks5_server.dart';
import 'state_db.dart';
import 'tunnel_client.dart';

class BtunClientRuntime {
  BtunClientRuntime({
    required this.bale,
    required this.stateDb,
    required this.transport,
    required this.chunkTransport,
    required this.tunnelClient,
    required this.socksServer,
    required this.logger,
  });

  final BaleClient bale;
  final StateDb stateDb;
  final BaleSavedMessagesTransport transport;
  final ChunkTransport chunkTransport;
  final BtunClient tunnelClient;
  final Socks5Server socksServer;
  final Logger logger;

  String get host => socksServer.host;
  int get port => socksServer.port;

  Future<void> start() async {
    await socksServer.start();
    logger.info('SOCKS5 listening on ${socksServer.host}:${socksServer.port}');
    final stateSub = bale.updates.listen((update) {
      if (update case BaleConnectionStateUpdate(:final state)) {
        logger.info('Bale connection: ${state.name}');
      }
    });
    try {
      logger.info('Connecting to Bale...');
      await bale.connect().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw Exception(
            'Timed out connecting to Bale. Check network access to Bale.',
          );
        },
      );
      await chunkTransport.start();
      logger.info('Tunnel transport started.');
    } on Object {
      await socksServer.close();
      rethrow;
    } finally {
      await stateSub.cancel();
    }
  }

  Future<void> close() async {
    await socksServer.close();
    await chunkTransport.close();
    await transport.close();
    stateDb.close();
    await bale.close();
  }
}

Future<BtunClientRuntime> createBtunClientRuntime({
  required BtunConfig config,
  required Logger logger,
  int? socksPort,
}) async {
  if (config.peerPublicKey == null || config.peerPublicKey!.isEmpty) {
    throw Exception(
      'peer_public_key is missing; exchange keys with btun init first',
    );
  }
  final bale = BaleClient(
    credentialsStore: FileBaleCredentialsStore(config.sessionFile),
  );
  final restored = await bale.restoreSession();
  if (restored == null) {
    throw Exception('no Bale session; log in first');
  }
  final crypto = await BtunCrypto.fromConfig(
    config,
    send: Direction.c2r,
    receive: Direction.r2c,
  );
  final state = StateDb.open(config.database);
  final transport = BaleSavedMessagesTransport(
    client: bale,
    sessionId: config.sessionId,
    sendDirection: Direction.c2r,
    receiveDirection: Direction.r2c,
    pollInterval: config.pollInterval,
    stateDb: state,
    uploadMinInterval: config.uploadMinInterval,
    uploadRateLimitPerMinute: config.uploadRateLimitPerMinute,
    logger: logger,
    maxConcurrentUploads: config.maxInFlight,
  );
  final chunkTransport = ChunkTransport(
    transport: transport,
    crypto: crypto,
    stateDb: state,
    sessionId: config.sessionId,
    sendDirection: Direction.c2r,
    receiveDirection: Direction.r2c,
    chunkSize: config.chunkSize,
    bulkChunkSize: config.bulkChunkSize,
    retryTimeout: config.retryTimeout,
    maxInFlight: config.maxInFlight,
    logger: logger,
    maxRetryChunks: config.maxRetryChunks,
    maxRetryBytes: config.maxRetryBytes,
    flushDelay: config.flushDelay,
    bulkFlushDelay: config.bulkFlushDelay,
    ackDelay: config.ackFlushInterval,
  );
  final client = BtunClient(config: config, chunkTransport: chunkTransport);
  final server = Socks5Server(
    host: config.socksHost,
    port: socksPort ?? config.socksPort,
    client: client,
    logger: logger,
  );
  return BtunClientRuntime(
    bale: bale,
    stateDb: state,
    transport: transport,
    chunkTransport: chunkTransport,
    tunnelClient: client,
    socksServer: server,
    logger: logger,
  );
}
