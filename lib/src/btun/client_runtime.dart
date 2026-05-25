import 'dart:async';

import 'package:bale_client/bale_client.dart';

import 'chunk_transport.dart';
import 'config.dart';
import 'config_reload.dart';
import 'crypto.dart';
import 'logger.dart';
import 'protocol.dart';
import 'saved_messages_transport.dart';
import 'socks5_server.dart';
import 'state_db.dart';
import 'tunnel_client.dart';
import 'tunnel_transport.dart';

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
    required this.config,
  });

  BtunConfig config;
  BaleClient bale;
  final List<BaleClient> accountClients;
  final StateDb stateDb;
  final LoadBalancedSavedMessagesTransport transport;
  final ChunkTransport chunkTransport;
  final BtunClient tunnelClient;
  final Socks5Server socksServer;
  final Logger logger;
  final _stateSubs = <int, StreamSubscription<BaleUpdate>>{};

  String get host => socksServer.host;
  int get port => socksServer.port;

  Future<void> start() async {
    await socksServer.start();
    logger.info('SOCKS5 listening on ${socksServer.host}:${socksServer.port}');
    try {
      logger.info('Connecting to Bale...');
      for (final client in accountClients) {
        final userId = client.session?.userId ?? 'unknown';
        _watchState(client);
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
    }
  }

  Future<BtunConfigReloadMode> reloadConfig(BtunConfig nextConfig) async {
    final diff = BtunConfigDiff.compare(config, nextConfig);
    if (!diff.hasChanges) return BtunConfigReloadMode.none;
    if (diff.requiresRebuild) {
      logger.warn(
        'config changed; runtime rebuild required: ${diff.reasons.join(', ')}',
      );
      return BtunConfigReloadMode.rebuild;
    }
    logger.info(
      'config changed; applying live reload: ${diff.reasons.join(', ')}',
    );
    await _reloadAccounts(nextConfig);
    transport.updateAccountSettings(
      pollInterval: nextConfig.pollInterval,
      maxPollInterval: nextConfig.maxPollInterval,
      uploadMinInterval: nextConfig.uploadMinInterval,
      uploadRateLimitPerMinute: nextConfig.uploadRateLimitPerMinute,
      maxConcurrentUploads: nextConfig.maxInFlight,
    );
    config = nextConfig;
    return BtunConfigReloadMode.live;
  }

  Future<void> _reloadAccounts(BtunConfig nextConfig) async {
    final enabled = {
      for (final account in nextConfig.enabledAccounts) account.userId: account,
    };
    for (final client in accountClients.toList()) {
      final userId = client.session?.userId;
      if (userId == null || !enabled.containsKey(userId)) {
        if (accountClients.length == 1) {
          logger.warn('ignored removal of last active Bale account $userId');
          continue;
        }
        await transport.removeAccount(userId!);
        await _stateSubs.remove(userId)?.cancel();
        accountClients.remove(client);
        await client.close();
        logger.info('removed Bale account $userId from runtime');
      }
    }
    final active = {
      for (final client in accountClients) client.session?.userId,
    };
    for (final account in enabled.values) {
      if (active.contains(account.userId)) continue;
      final client = BaleClient(
        credentialsStore: FileBaleCredentialsStore(account.sessionFile),
      );
      try {
        final restored = await client.restoreSession();
        if (restored?.userId != account.userId) {
          await client.close();
          logger.warn(
            'skipped Bale account ${account.userId}: session mismatch',
          );
          continue;
        }
        await client.connect().timeout(const Duration(seconds: 20));
        final accountTransport = BaleSavedMessagesTransport(
          client: client,
          sessionId: nextConfig.sessionId,
          sendDirection: Direction.c2r,
          receiveDirection: Direction.r2c,
          pollInterval: nextConfig.pollInterval,
          maxPollInterval: nextConfig.maxPollInterval,
          stateDb: stateDb,
          uploadMinInterval: nextConfig.uploadMinInterval,
          uploadRateLimitPerMinute: nextConfig.uploadRateLimitPerMinute,
          logger: logger,
          maxConcurrentUploads: nextConfig.maxInFlight,
          accountUserId: account.userId,
          onTraffic: transport.onTraffic,
        );
        await transport.addAccount(account.userId, accountTransport);
        accountClients.add(client);
        _watchState(client);
        if (accountClients.length == 1) bale = client;
        logger.info('added Bale account ${account.userId} to runtime');
      } on Object catch (error) {
        await client.close();
        logger.warn('failed to add Bale account ${account.userId}: $error');
      }
    }
  }

  void _watchState(BaleClient client) {
    final userId = client.session?.userId;
    if (userId == null || _stateSubs.containsKey(userId)) return;
    _stateSubs[userId] = client.updates.listen((update) {
      if (update case BaleConnectionStateUpdate(:final state)) {
        logger.info('Bale account $userId connection: ${state.name}');
      }
    });
  }

  Future<void> close() async {
    for (final sub in _stateSubs.values) {
      await sub.cancel();
    }
    _stateSubs.clear();
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
  TunnelTrafficCallback? onTraffic,
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
          maxPollInterval: config.maxPollInterval,
          stateDb: state,
          uploadMinInterval: config.uploadMinInterval,
          uploadRateLimitPerMinute: config.uploadRateLimitPerMinute,
          logger: logger,
          maxConcurrentUploads: config.maxInFlight,
          accountUserId: client.session?.userId,
          onTraffic: onTraffic,
        ),
    ],
    logger: logger,
    onTraffic: onTraffic,
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
    interactiveChunkSize: config.interactiveChunkSize,
    interactiveFlushDelay: config.flushDelay,
    controlFlushDelay: const Duration(milliseconds: 100),
    ackDelay: config.maxAckFlushInterval,
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
    config: config,
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
