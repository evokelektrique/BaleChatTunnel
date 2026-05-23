import 'dart:async';

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
    required this.accountClients,
    required this.stateDb,
    required this.transport,
    required this.chunkTransport,
    required this.tunnelClient,
    required this.socksServer,
    required this.logger,
  });

  final BaleClient bale;
  final List<BaleClient> accountClients;
  final StateDb stateDb;
  final LoadBalancedSavedMessagesTransport transport;
  final ChunkTransport chunkTransport;
  final BtunClient tunnelClient;
  final Socks5Server socksServer;
  final Logger logger;

  String get host => socksServer.host;
  int get port => socksServer.port;

  Future<void> start() async {
    await socksServer.start();
    logger.info('SOCKS5 listening on ${socksServer.host}:${socksServer.port}');
    final stateSubs = <StreamSubscription<BaleUpdate>>[];
    try {
      logger.info('Connecting to Bale...');
      for (final client in accountClients) {
        final userId = client.session?.userId ?? 'unknown';
        stateSubs.add(
          client.updates.listen((update) {
            if (update case BaleConnectionStateUpdate(:final state)) {
              logger.info('Bale account $userId connection: ${state.name}');
            }
          }),
        );
        await client.connect().timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            throw Exception(
              'Timed out connecting Bale account $userId. Check network access to Bale.',
            );
          },
        );
      }
      await chunkTransport.start();
      logger.info('Tunnel transport started.');
    } on Object {
      await socksServer.close();
      rethrow;
    } finally {
      for (final sub in stateSubs) {
        await sub.cancel();
      }
    }
  }

  Future<void> close() async {
    await socksServer.close();
    await chunkTransport.close();
    await transport.close();
    stateDb.close();
    for (final client in accountClients) {
      await client.close();
    }
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
  final clients = await _restoreAccountClients(config);
  final bale = clients.first;
  final crypto = await BtunCrypto.fromConfig(
    config,
    send: Direction.c2r,
    receive: Direction.r2c,
  );
  final state = StateDb.open(config.database);
  final transport = LoadBalancedSavedMessagesTransport(
    transports: [
      for (final client in clients)
        BaleSavedMessagesTransport(
          client: client,
          sessionId: config.sessionId,
          sendDirection: Direction.c2r,
          receiveDirection: Direction.r2c,
          pollInterval: config.pollInterval,
          stateDb: state,
          uploadMinInterval: config.uploadMinInterval,
          uploadRateLimitPerMinute: config.uploadRateLimitPerMinute,
          logger: logger,
          maxConcurrentUploads: config.maxInFlight,
          accountUserId: client.session?.userId,
        ),
    ],
    logger: logger,
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
    accountClients: clients,
    stateDb: state,
    transport: transport,
    chunkTransport: chunkTransport,
    tunnelClient: client,
    socksServer: server,
    logger: logger,
  );
}

Future<List<BaleClient>> _restoreAccountClients(BtunConfig config) async {
  final clients = <BaleClient>[];
  for (final account in config.enabledAccounts) {
    final client = BaleClient(
      credentialsStore: FileBaleCredentialsStore(account.sessionFile),
    );
    final restored = await client.restoreSession();
    if (restored == null) {
      await client.close();
      continue;
    }
    if (restored.userId == null) {
      await client.close();
      continue;
    }
    clients.add(client);
  }
  if (clients.isEmpty) {
    throw Exception(
      'no enabled Bale accounts with saved sessions; add an account first',
    );
  }
  return clients;
}
