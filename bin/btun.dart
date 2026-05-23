import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:bale_client/bale_client.dart';

const _uploadTestExtensions = [
  'txt',
  'csv',
  'log',
  'md',
  'json',
  'xml',
  'yaml',
  'yml',
  'html',
  'css',
  'js',
  'ts',
  'dart',
  'py',
  'java',
  'kt',
  'swift',
  'c',
  'cpp',
  'h',
  'sh',
  'sql',
  'pdf',
  'jpg',
  'webp',
  'bmp',
  'svg',
  'gz',
  'tar',
  'rar',
  '7z',
  'mp3',
  'wav',
  'ogg',
  'mp4',
  'mov',
  'webm',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'apk',
  'ipa',
  'exe',
  'dll',
  'so',
  'dylib',
  'wasm',
  'sqlite',
  'db',
  'pem',
  'crt',
  'key',
  'bin',
];

const _gifBytes = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00];
const _jpegBytes = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0xff, 0xd9];
const _pngBytes = [
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
];
const _zipBytes = [
  0x50,
  0x4b,
  0x05,
  0x06,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
];

Future<void> main(List<String> args) async {
  final cli = BtunCli(args);
  await cli.run();
}

class _UploadTestCase {
  const _UploadTestCase(this.name, this.bytes, this.mimeType);

  final String name;
  final List<int> bytes;
  final String mimeType;

  String get label {
    final dot = name.lastIndexOf('.');
    return dot == -1 ? 'no-extension' : name.substring(dot + 1);
  }
}

class _UploadTestResult {
  const _UploadTestResult({
    required this.uploadElapsed,
    required this.downloadElapsed,
    required this.attempts,
  });

  final Duration uploadElapsed;
  final Duration downloadElapsed;
  final int attempts;
}

class BtunCli {
  BtunCli(this.args);

  final List<String> args;

  Future<void> run() async {
    final command = args.isEmpty ? 'help' : args.first;
    try {
      switch (command) {
        case 'login':
          await _login();
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
        case 'upload-test':
          await _uploadTest();
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

  Future<void> _login() async {
    final profile = _profileDir();
    final sessionFile =
        _value('session') ?? BtunConfig.defaultSessionPath(profile);
    await _loginWithSessionFile(sessionFile);
  }

  Future<bool> _loginForSetup(String profile, String sessionFile) async {
    stdout.writeln('Using profile $profile for login.');
    try {
      await _loginWithSessionFile(sessionFile);
      return true;
    } on Object catch (error) {
      stdout.writeln('Login skipped or failed: $error');
      return false;
    }
  }

  Future<void> _loginWithSessionFile(String sessionFile) async {
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
      stdout.writeln(
        'Logged in as userId=${client.session?.userId ?? 'unknown'}',
      );
      stdout.writeln('Session stored at $sessionFile');
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
    final sessionFile =
        _value('session') ?? BtunConfig.defaultSessionPath(profile);
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
          sessionFile: sessionFile,
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
    stdout.writeln('session_file: ${config.sessionFile}');
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
    final stateSub = runtime.bale.updates.listen((update) {
      if (update case BaleConnectionStateUpdate(:final state)) {
        stdout.writeln('Bale connection: ${state.name}');
      }
    });
    try {
      stdout.writeln('Connecting to Bale...');
      await runtime.bale.connect().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw Exception(
            'Timed out connecting to Bale. Check network access to Bale.',
          );
        },
      );
      await runtime.start();
      stdout.writeln('Client ready for session ${config.sessionId}');
      await _waitForSignal();
    } finally {
      await stateSub.cancel();
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
    final stateSub = runtime.bale.updates.listen((update) {
      if (update case BaleConnectionStateUpdate(:final state)) {
        stdout.writeln('Bale connection: ${state.name}');
      }
    });
    try {
      stdout.writeln('Connecting to Bale...');
      await runtime.bale.connect().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw Exception(
            'Timed out connecting to Bale. Check network access to Bale.',
          );
        },
      );
      await runtime.start();
      await relay.start();
      stdout.writeln(
        'Relay watching Saved Messages for session ${config.sessionId}',
      );
      await _waitForSignal();
    } finally {
      await stateSub.cancel();
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

  Future<void> _uploadTest() async {
    final config = await _loadConfig();
    final bale = BaleClient(
      credentialsStore: FileBaleCredentialsStore(config.sessionFile),
    );
    try {
      stdout.writeln('Upload test: connecting');
      final restored = await bale.restoreSession(connect: true);
      if (restored == null) {
        throw Exception('no Bale session; run btun login first');
      }
      final userId = bale.session?.userId;
      if (userId == null) throw Exception('Bale session has no userId');
      final startedAt = DateTime.now().millisecondsSinceEpoch;
      final cases = _uploadTestCases(startedAt);
      final delay = Duration(
        milliseconds: int.tryParse(_value('upload-delay-ms') ?? '') ?? 1000,
      );
      final retries = int.tryParse(_value('retries') ?? '') ?? 1;
      final failures = <String>[];

      for (var i = 0; i < cases.length; i++) {
        if (i > 0 && delay > Duration.zero) await Future<void>.delayed(delay);
        final testCase = cases[i];
        final prefix = '[${i + 1}/${cases.length}] ${testCase.name}';
        try {
          final result = await _runUploadTestCase(
            bale,
            BalePeer.private(userId),
            testCase,
            retries: retries,
          );
          stdout.writeln(
            '$prefix ok (${testCase.bytes.length} bytes) '
            'upload=${result.uploadElapsed.inMilliseconds}ms '
            'download=${result.downloadElapsed.inMilliseconds}ms '
            'attempts=${result.attempts}',
          );
        } catch (error) {
          failures.add('${testCase.label}: $error');
          stdout.writeln('$prefix failed ${_formatUploadTestError(error)}');
        }
      }
      final passed = cases.length - failures.length;
      if (failures.isEmpty) {
        stdout.writeln('Upload test passed: $passed/${cases.length}');
      } else {
        stdout.writeln(
          'Upload test finished: $passed/${cases.length} passed; '
          'failed: ${failures.join(' | ')}',
        );
      }
    } finally {
      await bale.close();
    }
  }

  List<_UploadTestCase> _uploadTestCases(int runId) {
    final commonPayload = utf8.encode('btun upload test $runId');
    final cases = <_UploadTestCase>[
      _UploadTestCase('btun_upload_test_$runId.png', _pngBytes, 'image/png'),
      _UploadTestCase('btun_upload_test_$runId.jpeg', _jpegBytes, 'image/jpeg'),
      _UploadTestCase(
        'btun_upload_test_$runId.zip',
        _zipBytes,
        'application/zip',
      ),
      _UploadTestCase('btun_upload_test_$runId.gif', _gifBytes, 'image/gif'),
      _UploadTestCase(
        'btun_upload_test_$runId',
        commonPayload,
        'application/octet-stream',
      ),
    ];

    for (final extension in _uploadTestExtensions) {
      cases.add(
        _UploadTestCase(
          'btun_upload_test_$runId.$extension',
          utf8.encode('btun upload test $runId .$extension'),
          _mimeTypeForExtension(extension),
        ),
      );
    }
    return cases;
  }

  Future<_UploadTestResult> _runUploadTestCase(
    BaleClient bale,
    BalePeer peer,
    _UploadTestCase testCase, {
    required int retries,
  }) async {
    Object? lastError;
    final attempts = retries < 0 ? 1 : retries + 1;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final uploadWatch = Stopwatch()..start();
        final message = await bale.sendDocument(
          peer: peer,
          file: BaleFileInput.bytes(
            testCase.bytes,
            name: testCase.name,
            mimeType: testCase.mimeType,
          ),
        );
        uploadWatch.stop();
        final document = message.document;
        if (document == null) {
          throw Exception('upload returned no document');
        }
        final downloadWatch = Stopwatch()..start();
        final downloaded = await bale.downloadFile(
          fileId: document.fileId,
          accessHash: document.accessHash,
        );
        downloadWatch.stop();
        if (base64Encode(downloaded) != base64Encode(testCase.bytes)) {
          throw Exception(
            'download mismatch: sent ${testCase.bytes.length}, '
            'got ${downloaded.length}',
          );
        }
        return _UploadTestResult(
          uploadElapsed: uploadWatch.elapsed,
          downloadElapsed: downloadWatch.elapsed,
          attempts: attempt,
        );
      } catch (error) {
        lastError = error;
        if (attempt < attempts) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }
    Error.throwWithStackTrace(lastError!, StackTrace.current);
  }

  String _formatUploadTestError(Object error) {
    if (error is BaleHttpException) {
      final details = [
        'stage=${error.stage}',
        'status=${error.statusCode}',
        'host=${error.host}',
        'elapsed=${error.elapsed.inMilliseconds}ms',
        ...error.headers.entries.map((entry) => '${entry.key}=${entry.value}'),
      ];
      final body = error.body.trim();
      if (body.isNotEmpty) details.add('body=$body');
      return details.join(' ');
    }
    return error.toString();
  }

  String _mimeTypeForExtension(String extension) => switch (extension) {
    'txt' ||
    'csv' ||
    'log' ||
    'md' ||
    'json' ||
    'xml' ||
    'yaml' ||
    'yml' ||
    'html' ||
    'css' ||
    'js' ||
    'ts' ||
    'dart' ||
    'py' ||
    'java' ||
    'kt' ||
    'swift' ||
    'c' ||
    'cpp' ||
    'h' ||
    'sh' ||
    'sql' => 'text/plain',
    'jpg' => 'image/jpeg',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'svg' => 'image/svg+xml',
    'pdf' => 'application/pdf',
    'gz' => 'application/gzip',
    'tar' => 'application/x-tar',
    'rar' => 'application/vnd.rar',
    '7z' => 'application/x-7z-compressed',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'ogg' => 'audio/ogg',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    _ => 'application/octet-stream',
  };

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
    final bale = BaleClient(
      credentialsStore: FileBaleCredentialsStore(config.sessionFile),
    );
    final restored = await bale.restoreSession(connect: false);
    if (restored == null) {
      throw Exception('no Bale session; run btun login first');
    }
    final crypto = await BtunCrypto.fromConfig(
      config,
      send: send,
      receive: receive,
    );
    final state = StateDb.open(config.database);
    final transport = BaleSavedMessagesTransport(
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
    return BtunRuntime(bale, state, transport, chunkTransport);
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
  btun status
  btun relay
  btun client [--socks-port 1080]
  btun http-test
  btun upload-test

Examples:
  btun setup --profile .btun-relay
  btun init --profile .btun-relay --client-public-key <base64>
  btun relay --profile .btun-relay

Options:
  --profile <dir>          Default: .btun
  --config <path>          Default: <profile>/config.json
  --session <path>         Default: <profile>/session.json
  --role <client|relay>    Setup role override
  --session-id <id>        Override session id
  --transport-preset <p>   interactive, stable, resilient, or custom
  --upload-delay-ms <n>    upload-test delay between files. Default: 1000
  --retries <n>            upload-test retries per file. Default: 1
  --peer-public-key <key>  Public key from the other side
  --client-public-key <key> Alias for peer key when this machine is relay
  --relay-public-key <key> Alias for peer key when this machine is client
  --verbose                Print stack traces on errors
''');
  }
}

class BtunRuntime {
  BtunRuntime(this.bale, this.stateDb, this.transport, this.chunkTransport);

  final BaleClient bale;
  final StateDb stateDb;
  final BaleSavedMessagesTransport transport;
  final ChunkTransport chunkTransport;

  Future<void> start() => chunkTransport.start();

  Future<void> close() async {
    await chunkTransport.close();
    await transport.close();
    stateDb.close();
    await bale.close();
  }
}
