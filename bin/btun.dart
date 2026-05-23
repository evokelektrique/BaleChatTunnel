import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:bale_client/bale_client.dart';

Future<void> main(List<String> args) async {
  final cli = BtunCli(args);
  await cli.run();
}

class BtunCli {
  BtunCli(this.args);

  final List<String> args;

  Future<void> run() async {
    final command = args.isEmpty ? 'help' : args.first;
    try {
      switch (command) {
        case 'login':
          await _accountAdd();
        case 'account':
          await _account();
        case 'setup':
          await _setup();
        case 'init':
          await _init();
        case 'status':
          await _status();
        case 'client':
          await _runClient();
        case 'relay':
          await _runRelay();
        case 'http-test':
          await _httpTest();
        case 'help':
        case '--help':
        case '-h':
          _printHelp();
        default:
          stderr.writeln('Unknown command: $command');
          _printHelp();
          exitCode = 64;
      }
    } on Object catch (error, stack) {
      stderr.writeln('btun: $error');
      if (_flag('verbose')) stderr.writeln(stack);
      exitCode = 1;
    }
  }

  Future<BtunAccountConfig?> _loginForSetup(String profile) async {
    stdout.writeln('Using profile $profile for account login.');
    try {
      return await _loginAndRegisterAccount(profile);
    } on Object catch (error) {
      stdout.writeln('Login skipped or failed: $error');
      return null;
    }
  }

  Future<BaleSession> _loginWithSessionFile(String sessionFile) async {
    final client = BaleClient(
      credentialsStore: FileBaleCredentialsStore(sessionFile),
    );
    try {
      stdout.write('Phone number (+98912...): ');
      final phone = stdin.readLineSync()?.trim();
      if (phone == null || phone.isEmpty) throw Exception('phone is required');

      final started = await client.startPhoneAuth(phone);
      stdout.writeln('Code sent. registered=${started.isRegistered}');
      stdout.write('Code: ');
      final code = stdin.readLineSync()?.trim();
      if (code == null || code.isEmpty) throw Exception('code is required');

      try {
        await client.validateCode(
          transactionHash: started.transactionHash,
          code: code,
        );
      } on BaleAuthException catch (error) {
        if (error.authError == BaleAuthError.passwordNeeded) {
          stdout.write('Two-factor password: ');
          final password = stdin.readLineSync()?.trim();
          if (password == null || password.isEmpty) {
            throw Exception('password is required');
          }
          await client.validatePassword(
            transactionHash: started.transactionHash,
            password: password,
          );
        } else if (error.authError == BaleAuthError.signUpNeeded) {
          stdout.write('New account name: ');
          final name = stdin.readLineSync()?.trim();
          if (name == null || name.isEmpty) throw Exception('name is required');
          await client.signUp(
            transactionHash: started.transactionHash,
            name: name,
          );
        } else {
          rethrow;
        }
      }
      final session = client.session;
      final userId = session?.userId;
      if (session == null || userId == null) {
        throw Exception('login completed without a Bale user id');
      }
      stdout.writeln('Logged in as userId=$userId');
      stdout.writeln('Session stored at $sessionFile');
      return session;
    } finally {
      await client.close();
    }
  }

  Future<void> _setup() async {
    final wizard = BtunSetupWizard.stdio(
      stdin: stdin,
      stdout: stdout,
      profileFromArgs: _value('profile'),
      configPathFromArgs: _value('config'),
      sessionPathFromArgs: _value('session'),
      roleFromArgs: _roleValue('role'),
      loginRunner: _loginForSetup,
    );
    await wizard.run();
  }

  Future<void> _init() async {
    final profile = _profileDir();
    final configPath =
        _value('config') ?? BtunConfig.defaultConfigPath(profile);
    final existing = await BtunConfig.tryLoad(configPath);
    final sessionId =
        _value('session-id') ??
        existing?.sessionId ??
        BtunConfig.randomSessionId();
    final localKeys = existing == null
        ? await BtunCrypto.generateKeyPair()
        : KeyPairConfig(
            publicKey: existing.localPublicKey,
            privateKey: existing.localPrivateKey,
          );

    final peerPublicKey =
        _value('peer-public-key') ??
        _value('client-public-key') ??
        _value('relay-public-key') ??
        existing?.peerPublicKey;
    var config = (existing ?? BtunConfig.defaults(profileDir: profile))
        .copyWith(
          sessionId: sessionId,
          localPublicKey: localKeys.publicKey,
          localPrivateKey: localKeys.privateKey,
          peerPublicKey: peerPublicKey,
        );
    final transportPreset = _transportPresetValue('transport-preset');
    if (transportPreset != null) {
      config = config.applyTransportPreset(transportPreset);
    }
    await config.save(configPath);
    stdout.writeln('Wrote $configPath');
    stdout.writeln('session_id: ${config.sessionId}');
    stdout.writeln('${_localKeyLabel(config.role)}: ${config.localPublicKey}');
    if (config.peerPublicKey == null || config.peerPublicKey!.isEmpty) {
      stdout.writeln('Set ${_peerKeyLabel(config.role)} with:');
      stdout.writeln(
        '  btun init --profile $profile --peer-public-key ${_peerKeyPlaceholder(config.role)}',
      );
    }
  }

  Future<void> _status() async {
    final config = await _loadConfig();
    stdout.writeln('profile: ${_profileDir()}');
    stdout.writeln('session_id: ${config.sessionId}');
    stdout.writeln('${_localKeyLabel(config.role)}: ${config.localPublicKey}');
    stdout.writeln(
      '${_peerStatusLabel(config.role)}: ${config.peerPublicKey ?? '<not set>'}',
    );
    stdout.writeln('socks: ${config.socksHost}:${config.socksPort}');
    stdout.writeln('transport_preset: ${config.transportPreset.name}');
    stdout.writeln('chunk_size: ${config.chunkSize}');
    stdout.writeln('poll_interval_ms: ${config.pollInterval.inMilliseconds}');
    stdout.writeln('retry_timeout_ms: ${config.retryTimeout.inMilliseconds}');
    stdout.writeln(
      'upload_min_interval_ms: ${config.uploadMinInterval.inMilliseconds}',
    );
    stdout.writeln(
      'upload_rate_limit_per_minute: ${config.uploadRateLimitPerMinute}',
    );
    stdout.writeln(
      'ack_flush_interval_ms: ${config.ackFlushInterval.inMilliseconds}',
    );
    stdout.writeln('flush_delay_ms: ${config.flushDelay.inMilliseconds}');
    stdout.writeln(
      'bulk_flush_delay_ms: ${config.bulkFlushDelay.inMilliseconds}',
    );
    stdout.writeln('bulk_chunk_size: ${config.bulkChunkSize}');
    stdout.writeln('max_retry_chunks: ${config.maxRetryChunks}');
    stdout.writeln('max_retry_bytes: ${config.maxRetryBytes}');
    stdout.writeln('accounts: ${config.accounts.length}');
    stdout.writeln('enabled_accounts: ${config.enabledAccounts.length}');
    for (final account in config.accounts) {
      stdout.writeln(
        'account ${account.userId}: enabled=${account.enabled} '
        'session=${account.sessionFile}',
      );
    }
  }

  Future<void> _account() async {
    final subcommand = args.length < 2 ? 'help' : args[1];
    switch (subcommand) {
      case 'add':
        await _accountAdd();
      case 'list':
        await _accountList();
      case 'remove':
        await _accountRemove();
      case 'enable':
        await _accountEnable(true);
      case 'disable':
        await _accountEnable(false);
      case 'help':
      case '--help':
      case '-h':
        _printAccountHelp();
      default:
        throw Exception('unknown account command: $subcommand');
    }
  }

  Future<void> _accountAdd() async {
    final account = await _loginAndRegisterAccount(_profileDir());
    stdout.writeln('Added account ${account.userId}');
  }

  Future<BtunAccountConfig> _loginAndRegisterAccount(String profile) async {
    final configPath =
        _value('config') ?? BtunConfig.defaultConfigPath(profile);
    var config =
        await BtunConfig.tryLoad(configPath) ??
        BtunConfig.defaults(profileDir: profile);
    final pendingPath =
        '${BtunConfig.defaultAccountsDir(profile)}/pending.session.json';
    final session = await _loginWithSessionFile(pendingPath);
    final userId = session.userId;
    if (userId == null) throw Exception('login completed without a user id');
    final sessionPath = BtunConfig.accountSessionPath(profile, userId);
    final pendingFile = File(pendingPath);
    final sessionFile = File(sessionPath);
    await sessionFile.parent.create(recursive: true);
    if (await sessionFile.exists()) await sessionFile.delete();
    await pendingFile.rename(sessionPath);
    final account = BtunAccountConfig(
      userId: userId,
      sessionFile: sessionPath,
      enabled: true,
    );
    config = config.upsertAccount(account);
    await config.save(configPath);
    return account;
  }

  Future<void> _accountList() async {
    final config = await _loadConfig();
    if (config.accounts.isEmpty) {
      stdout.writeln('No accounts configured.');
      return;
    }
    for (final account in config.accounts) {
      stdout.writeln(
        '${account.userId}\t'
        'enabled=${account.enabled}\t'
        '${account.sessionFile}',
      );
    }
  }

  Future<void> _accountRemove() async {
    final userId = _accountUserIdArg();
    final matches = (await _loadConfig()).accounts.where(
      (account) => account.userId == userId,
    );
    final account = matches.isEmpty ? null : matches.first;
    if (account == null) throw Exception('unknown account: $userId');
    await _updateConfig((config) => config.removeAccount(userId));
    final file = File(account.sessionFile);
    if (await file.exists()) await file.delete();
    stdout.writeln('Removed account $userId');
  }

  Future<void> _accountEnable(bool enabled) async {
    final userId = _accountUserIdArg();
    await _updateConfig((config) => config.setAccountEnabled(userId, enabled));
    stdout.writeln('${enabled ? 'Enabled' : 'Disabled'} account $userId');
  }

  int _accountUserIdArg() {
    if (args.length < 3) throw Exception('account user id is required');
    return int.parse(args[2]);
  }

  Future<void> _updateConfig(BtunConfig Function(BtunConfig) update) async {
    final profile = _profileDir();
    final configPath =
        _value('config') ?? BtunConfig.defaultConfigPath(profile);
    await update(await BtunConfig.load(configPath)).save(configPath);
  }

  Future<void> _runClient() async {
    stdout.writeln('Loading client config...');
    final config = await _loadConfig(role: BtunRole.client);
    stdout.writeln(
      'Preparing Bale transport for session ${config.sessionId}...',
    );
    final runtime = await _runtime(
      config,
      send: Direction.c2r,
      receive: Direction.r2c,
    );
    final client = BtunClient(
      config: config,
      chunkTransport: runtime.chunkTransport,
    );
    final server = Socks5Server(
      host: config.socksHost,
      port: int.parse(_value('socks-port') ?? config.socksPort.toString()),
      client: client,
      logger: Logger(),
    );
    await server.start();
    stdout.writeln('SOCKS5 listening on ${server.host}:${server.port}');
    final stateSubs = runtime.bales.map((bale) {
      final userId = bale.session?.userId ?? 'unknown';
      return bale.updates.listen((update) {
        if (update case BaleConnectionStateUpdate(:final state)) {
          stdout.writeln('Bale account $userId connection: ${state.name}');
        }
      });
    }).toList();
    try {
      stdout.writeln('Connecting to Bale...');
      await runtime.connectAll();
      await runtime.start();
      stdout.writeln('Client ready for session ${config.sessionId}');
      await _waitForSignal();
    } finally {
      for (final sub in stateSubs) {
        await sub.cancel();
      }
      await server.close();
      await runtime.close();
    }
  }

  Future<void> _runRelay() async {
    final config = await _loadConfig(role: BtunRole.relay);
    stdout.writeln('Preparing relay for session ${config.sessionId}...');
    final runtime = await _runtime(
      config,
      send: Direction.r2c,
      receive: Direction.c2r,
    );
    final relay = TcpRelay(
      chunkTransport: runtime.chunkTransport,
      policy: RelayPolicy.fromConfig(config),
      logger: Logger(),
    );
    final stateSubs = runtime.bales.map((bale) {
      final userId = bale.session?.userId ?? 'unknown';
      return bale.updates.listen((update) {
        if (update case BaleConnectionStateUpdate(:final state)) {
          stdout.writeln('Bale account $userId connection: ${state.name}');
        }
      });
    }).toList();
    try {
      stdout.writeln('Connecting to Bale...');
      await runtime.connectAll();
      await runtime.start();
      await relay.start();
      stdout.writeln(
        'Relay watching Saved Messages for session ${config.sessionId}',
      );
      await _waitForSignal();
    } finally {
      for (final sub in stateSubs) {
        await sub.cancel();
      }
      await relay.close();
      await runtime.close();
    }
  }

  Future<void> _httpTest() async {
    final config = await _loadConfig(role: BtunRole.client);
    final runtime = await _runtime(
      config,
      send: Direction.c2r,
      receive: Direction.r2c,
    );
    final client = BtunClient(
      config: config,
      chunkTransport: runtime.chunkTransport,
    );
    await runtime.start();
    final response = await client.requestBytes(
      'example.com',
      80,
      ascii.encode(
        'GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n',
      ),
      closeAfterWrite: true,
    );
    stdout.write(utf8.decode(response, allowMalformed: true));
    await runtime.close();
  }

  Future<BtunConfig> _loadConfig({BtunRole? role}) async {
    final profile = _profileDir();
    final path = _value('config') ?? BtunConfig.defaultConfigPath(profile);
    var config = await BtunConfig.load(path);
    if (role != null) config = config.copyWith(role: role);
    final sessionId = _value('session-id');
    if (sessionId != null) config = config.copyWith(sessionId: sessionId);
    return config;
  }

  Future<BtunRuntime> _runtime(
    BtunConfig config, {
    required Direction send,
    required Direction receive,
  }) async {
    if (config.peerPublicKey == null || config.peerPublicKey!.isEmpty) {
      throw Exception(
        'peer_public_key is missing; exchange keys with btun init first',
      );
    }
    final bales = await _restoreAccountClients(config);
    final bale = bales.first;
    final crypto = await BtunCrypto.fromConfig(
      config,
      send: send,
      receive: receive,
    );
    final state = StateDb.open(config.database);
    final transport = LoadBalancedSavedMessagesTransport(
      transports: [
        for (final bale in bales)
          BaleSavedMessagesTransport(
            client: bale,
            sessionId: config.sessionId,
            sendDirection: send,
            receiveDirection: receive,
            pollInterval: config.pollInterval,
            stateDb: state,
            uploadMinInterval: config.uploadMinInterval,
            uploadRateLimitPerMinute: config.uploadRateLimitPerMinute,
            logger: Logger(),
            maxConcurrentUploads: config.maxInFlight,
            accountUserId: bale.session?.userId,
          ),
      ],
      logger: Logger(),
    );
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: crypto,
      stateDb: state,
      sessionId: config.sessionId,
      sendDirection: send,
      receiveDirection: receive,
      chunkSize: config.chunkSize,
      bulkChunkSize: config.bulkChunkSize,
      retryTimeout: config.retryTimeout,
      maxInFlight: config.maxInFlight,
      logger: Logger(),
      maxRetryChunks: config.maxRetryChunks,
      maxRetryBytes: config.maxRetryBytes,
      flushDelay: config.flushDelay,
      bulkFlushDelay: config.bulkFlushDelay,
      ackDelay: config.ackFlushInterval,
    );
    return BtunRuntime(bale, bales, state, transport, chunkTransport);
  }

  Future<List<BaleClient>> _restoreAccountClients(BtunConfig config) async {
    final bales = <BaleClient>[];
    for (final account in config.enabledAccounts) {
      final bale = BaleClient(
        credentialsStore: FileBaleCredentialsStore(account.sessionFile),
      );
      final restored = await bale.restoreSession(connect: false);
      if (restored == null || restored.userId == null) {
        await bale.close();
        continue;
      }
      bales.add(bale);
    }
    if (bales.isEmpty) {
      throw Exception(
        'no enabled Bale accounts with saved sessions; run btun account add',
      );
    }
    return bales;
  }

  String _profileDir() {
    return _value('profile') ??
        Platform.environment['BTUN_PROFILE'] ??
        BtunConfig.defaultProfileDir();
  }

  bool _flag(String name) => args.contains('--$name');

  String? _value(String name) {
    final prefix = '--$name=';
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith(prefix)) return arg.substring(prefix.length);
      if (arg == '--$name' && i + 1 < args.length) return args[i + 1];
    }
    return null;
  }

  BtunTransportPreset? _transportPresetValue(String name) {
    final value = _value(name);
    if (value == null) return null;
    for (final preset in BtunTransportPreset.values) {
      if (preset.name == value.trim().toLowerCase()) return preset;
    }
    throw FormatException(
      'invalid --$name: enter one of interactive, stable, resilient, custom',
    );
  }

  BtunRole? _roleValue(String name) {
    final value = _value(name);
    if (value == null) return null;
    return switch (value.trim().toLowerCase()) {
      'client' => BtunRole.client,
      'relay' => BtunRole.relay,
      _ => throw Exception('invalid role: $value'),
    };
  }

  String _localKeyLabel(BtunRole role) => switch (role) {
    BtunRole.client => 'client_public_key',
    BtunRole.relay => 'relay_public_key',
  };

  String _peerKeyLabel(BtunRole role) => switch (role) {
    BtunRole.client => 'relay public key',
    BtunRole.relay => 'client public key',
  };

  String _peerStatusLabel(BtunRole role) => switch (role) {
    BtunRole.client => 'relay_public_key',
    BtunRole.relay => 'client_public_key',
  };

  String _peerKeyPlaceholder(BtunRole role) => switch (role) {
    BtunRole.client => 'RELAY_PUBLIC_KEY',
    BtunRole.relay => 'CLIENT_PUBLIC_KEY',
  };

  Future<void> _waitForSignal() async {
    if (Platform.isWindows) {
      await Completer<void>().future;
      return;
    }
    await ProcessSignal.sigint.watch().first;
  }

  void _printHelp() {
    stdout.writeln('''
Bale Saved Messages Tunnel

Usage:
  btun login
  btun setup
  btun init [--peer-public-key <base64>]
  btun account add|list|remove|enable|disable
  btun status
  btun relay
  btun client [--socks-port 1080]
  btun http-test

Examples:
  btun setup --profile .btun-relay
  btun init --profile .btun-relay --client-public-key <base64>
  btun relay --profile .btun-relay

Options:
  --profile <dir>          Default: .btun
  --config <path>          Default: <profile>/config.json
  --role <client|relay>    Setup role override
  --session-id <id>        Override session id
  --transport-preset <p>   interactive, stable, resilient, or custom
  --peer-public-key <key>  Public key from the other side
  --client-public-key <key> Alias for peer key when this machine is relay
  --relay-public-key <key> Alias for peer key when this machine is client
  --verbose                Print stack traces on errors
''');
  }

  void _printAccountHelp() {
    stdout.writeln('''
Bale account commands

Usage:
  btun account add
  btun account list
  btun account remove <user-id>
  btun account enable <user-id>
  btun account disable <user-id>
''');
  }
}

class BtunRuntime {
  BtunRuntime(
    this.bale,
    this.bales,
    this.stateDb,
    this.transport,
    this.chunkTransport,
  );

  final BaleClient bale;
  final List<BaleClient> bales;
  final StateDb stateDb;
  final LoadBalancedSavedMessagesTransport transport;
  final ChunkTransport chunkTransport;

  Future<void> connectAll() async {
    for (final bale in bales) {
      final userId = bale.session?.userId ?? 'unknown';
      await bale.connect().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw Exception(
            'Timed out connecting Bale account $userId. Check network access to Bale.',
          );
        },
      );
    }
  }

  Future<void> start() => chunkTransport.start();

  Future<void> close() async {
    await chunkTransport.close();
    await transport.close();
    stateDb.close();
    for (final bale in bales) {
      await bale.close();
    }
  }
}
