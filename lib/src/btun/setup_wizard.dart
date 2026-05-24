import 'dart:io';

import 'config.dart';
import 'crypto.dart';

typedef LoginRunner = Future<BtunAccountConfig?> Function(String profileDir);
typedef LineReader = String? Function();
typedef TextWriter = void Function(Object? object);
typedef TextAppender = void Function(Object? object);

class BtunSetupWizard {
  BtunSetupWizard({
    required this.readLine,
    required this.write,
    required this.writeln,
    required this.profileFromArgs,
    required this.configPathFromArgs,
    required this.sessionPathFromArgs,
    required this.roleFromArgs,
    required this.loginRunner,
  });

  BtunSetupWizard.stdio({
    required Stdin stdin,
    required Stdout stdout,
    required String? profileFromArgs,
    required String? configPathFromArgs,
    required String? sessionPathFromArgs,
    required BtunRole? roleFromArgs,
    required LoginRunner loginRunner,
  }) : this(
         readLine: stdin.readLineSync,
         write: stdout.write,
         writeln: stdout.writeln,
         profileFromArgs: profileFromArgs,
         configPathFromArgs: configPathFromArgs,
         sessionPathFromArgs: sessionPathFromArgs,
         roleFromArgs: roleFromArgs,
         loginRunner: loginRunner,
       );

  final LineReader readLine;
  final TextWriter write;
  final TextAppender writeln;
  final String? profileFromArgs;
  final String? configPathFromArgs;
  final String? sessionPathFromArgs;
  final BtunRole? roleFromArgs;
  final LoginRunner loginRunner;

  Future<BtunConfig> run() async {
    writeln('btun setup');
    writeln('Enter accepts the default. Type ? for help.');

    final envProfile = Platform.environment['BTUN_PROFILE'];
    final profileDefault =
        profileFromArgs ?? envProfile ?? BtunConfig.defaultProfileDir();
    final profile = profileFromArgs == null
        ? await promptString(
            'Profile directory',
            defaultValue: profileDefault,
            help:
                'Directory for btun config, Bale session, and local tunnel '
                'state. BTUN_PROFILE is used when set.',
          )
        : profileFromArgs!;
    if (profileFromArgs != null) writeln('Using profile $profile.');
    final configPath =
        configPathFromArgs ?? BtunConfig.defaultConfigPath(profile);
    final database = BtunConfig.defaultDatabasePath(profile);
    final existing = await BtunConfig.tryLoad(configPath);

    if (existing != null) {
      writeln('Found existing config at $configPath.');
      final update = await promptBool(
        'Update existing config',
        defaultValue: true,
        help:
            'Yes preserves existing keys and values unless you change them. '
            'No exits without writing.',
      );
      if (!update) {
        writeln('Setup cancelled.');
        return existing;
      }
    }

    final defaults = existing ?? BtunConfig.defaults(profileDir: profile);
    final role =
        roleFromArgs ??
        await promptRole(
          'This machine role (client/relay)',
          defaultValue: existing?.role ?? BtunRole.relay,
          help:
              'relay runs on the machine that connects to destination hosts. '
              'client runs a local SOCKS proxy.',
        );
    if (roleFromArgs != null) writeln('Using role ${role.name}.');

    var localPublicKey = defaults.localPublicKey;
    var localPrivateKey = defaults.localPrivateKey;
    if (localPublicKey.isEmpty || localPrivateKey.isEmpty) {
      final keys = await BtunCrypto.generateKeyPair();
      localPublicKey = keys.publicKey;
      localPrivateKey = keys.privateKey;
      writeln('Generated local keypair.');
    } else {
      writeln('Preserving existing local keypair.');
    }
    writeln('${_localKeyLabel(role)}: $localPublicKey');

    final sessionId = await promptString(
      'Session ID',
      defaultValue: defaults.sessionId.isEmpty
          ? BtunConfig.randomSessionId()
          : defaults.sessionId,
      help:
          'Shared tunnel name. Both sides must use the same session ID, but '
          'each side keeps its own local keypair.',
    );
    final peerPublicKey = await promptString(
      _peerKeyLabel(role),
      defaultValue: defaults.peerPublicKey ?? '',
      allowEmpty: true,
      help:
          'Public key from the other side of the tunnel. You may leave it '
          'empty now and add it after exchanging keys.',
    );

    writeln('');
    writeln('Client SOCKS');
    final socksHost = await promptString(
      'SOCKS host',
      defaultValue: defaults.socksHost,
      help: 'Host address for the local SOCKS5 listener used by client mode.',
    );
    final socksPort = await promptInt(
      'SOCKS port',
      defaultValue: defaults.socksPort,
      min: 1,
      max: 65535,
      help: 'TCP port for the local SOCKS5 listener used by client mode.',
    );

    writeln('');
    writeln('Transport/performance');
    writeln('1) Interactive - lower latency with stream limits');
    writeln('2) Stable - recommended');
    writeln('3) Resilient - safest upload cadence');
    writeln('4) Custom - edit every value');
    final transportPreset = await promptTransportPreset(
      'Stability preset number',
      defaultValue: defaults.transportPreset,
      help:
          'Enter 1, 2, 3, or 4. Names still work: interactive, stable, '
          'resilient, custom.',
    );
    final performanceDefaults = defaults.applyTransportPreset(transportPreset);
    var chunkSize = performanceDefaults.chunkSize;
    var bulkChunkSize = performanceDefaults.bulkChunkSize;
    var maxInFlight = performanceDefaults.maxInFlight;
    var pollMs = performanceDefaults.pollInterval.inMilliseconds;
    var retryMs = performanceDefaults.retryTimeout.inMilliseconds;
    var uploadMinMs = performanceDefaults.uploadMinInterval.inMilliseconds;
    var uploadRate = performanceDefaults.uploadRateLimitPerMinute;
    var ackMs = performanceDefaults.ackFlushInterval.inMilliseconds;
    var flushMs = performanceDefaults.flushDelay.inMilliseconds;
    var bulkFlushMs = performanceDefaults.bulkFlushDelay.inMilliseconds;
    var maxRetryChunks = performanceDefaults.maxRetryChunks;
    var maxRetryBytes = performanceDefaults.maxRetryBytes;
    var maxStreams = performanceDefaults.maxStreams;
    if (transportPreset == BtunTransportPreset.custom) {
      chunkSize = await promptInt(
        'Chunk size bytes',
        defaultValue: defaults.chunkSize,
        min: 1024,
        help: 'Maximum payload size for regular tunnel chunks.',
      );
      bulkChunkSize = await promptInt(
        'Bulk chunk size bytes',
        defaultValue: defaults.bulkChunkSize,
        min: 1024,
        help: 'Maximum payload size for larger queued chunks.',
      );
      maxInFlight = await promptInt(
        'Max in-flight uploads',
        defaultValue: defaults.maxInFlight,
        min: 1,
        help: 'Maximum concurrent Saved Messages uploads.',
      );
      pollMs = await promptInt(
        'Poll interval ms',
        defaultValue: defaults.pollInterval.inMilliseconds,
        min: 100,
        help: 'How often to poll Saved Messages when updates are quiet.',
      );
      retryMs = await promptInt(
        'Retry timeout ms',
        defaultValue: defaults.retryTimeout.inMilliseconds,
        min: 1000,
        help: 'How long to wait before retrying unacknowledged chunks.',
      );
      uploadMinMs = await promptInt(
        'Upload min interval ms',
        defaultValue: defaults.uploadMinInterval.inMilliseconds,
        min: 0,
        help: 'Minimum spacing between uploads. Use 0 for no fixed delay.',
      );
      uploadRate = await promptInt(
        'Upload rate limit per minute',
        defaultValue: defaults.uploadRateLimitPerMinute,
        min: 1,
        help: 'Maximum upload attempts per minute.',
      );
      ackMs = await promptInt(
        'ACK flush delay ms',
        defaultValue: defaults.ackFlushInterval.inMilliseconds,
        min: 0,
        help: 'Delay used to batch acknowledgements before sending.',
      );
      flushMs = await promptInt(
        'Flush delay ms',
        defaultValue: defaults.flushDelay.inMilliseconds,
        min: 0,
        help: 'Delay used to batch ordinary frames before upload.',
      );
      bulkFlushMs = await promptInt(
        'Bulk flush delay ms',
        defaultValue: defaults.bulkFlushDelay.inMilliseconds,
        min: 0,
        help: 'Delay used to batch larger transfer frames before upload.',
      );
      maxRetryChunks = await promptInt(
        'Max retry chunks',
        defaultValue: defaults.maxRetryChunks,
        min: 0,
        help: 'Maximum number of chunks retained for retry.',
      );
      maxRetryBytes = await promptInt(
        'Max retry bytes',
        defaultValue: defaults.maxRetryBytes,
        min: 0,
        help: 'Maximum total bytes retained for retry.',
      );
      maxStreams = await promptInt(
        'Max streams',
        defaultValue: defaults.maxStreams,
        min: 1,
        help: 'Maximum concurrent tunnel streams.',
      );
    }

    final config = defaults.copyWith(
      role: role,
      database: database,
      sessionId: sessionId,
      localPublicKey: localPublicKey,
      localPrivateKey: localPrivateKey,
      peerPublicKey: peerPublicKey,
      socksHost: socksHost,
      socksPort: socksPort,
      chunkSize: chunkSize,
      bulkChunkSize: bulkChunkSize,
      maxInFlight: maxInFlight,
      pollInterval: Duration(milliseconds: pollMs),
      retryTimeout: Duration(milliseconds: retryMs),
      uploadMinInterval: Duration(milliseconds: uploadMinMs),
      uploadRateLimitPerMinute: uploadRate,
      ackFlushInterval: Duration(milliseconds: ackMs),
      flushDelay: Duration(milliseconds: flushMs),
      bulkFlushDelay: Duration(milliseconds: bulkFlushMs),
      transportPreset: transportPreset,
      maxRetryChunks: maxRetryChunks,
      maxRetryBytes: maxRetryBytes,
      maxStreams: maxStreams,
    );
    var nextConfig = config;
    await nextConfig.save(configPath);
    writeln('');
    writeln('Wrote $configPath');

    var loggedIn = nextConfig.enabledAccounts.isNotEmpty;
    if (!loggedIn) {
      final runLogin = await promptBool(
        'No Bale account found. Add account now',
        defaultValue: true,
        help:
            'Login stores Bale credentials under the profile accounts '
            'directory. Setup can finish without an account.',
      );
      if (runLogin) {
        final account = await loginRunner(profile);
        if (account != null) {
          nextConfig = nextConfig.upsertAccount(account);
          await nextConfig.save(configPath);
          loggedIn = true;
        }
      }
    }

    printNextSteps(nextConfig, profile, configPath, loggedIn: loggedIn);
    return nextConfig;
  }

  void printNextSteps(
    BtunConfig config,
    String profile,
    String configPath, {
    required bool loggedIn,
  }) {
    writeln('');
    writeln('Next steps');
    writeln('session_id: ${config.sessionId}');
    writeln('${_localKeyLabel(config.role)}: ${config.localPublicKey}');
    if (config.peerPublicKey == null || config.peerPublicKey!.isEmpty) {
      writeln('Missing ${_peerKeyLabel(config.role)}.');
      writeln('After receiving it, run:');
      writeln(
        '  btun init --profile $profile --peer-public-key ${_peerKeyPlaceholder(config.role)}',
      );
    }
    if (!loggedIn) {
      writeln('Login when ready: btun login --profile $profile');
    }
    writeln(
      'Start ${config.role.name}: btun ${config.role.name} --profile $profile',
    );
  }

  String _localKeyLabel(BtunRole role) => switch (role) {
    BtunRole.client => 'client_public_key',
    BtunRole.relay => 'relay_public_key',
  };

  String _peerKeyLabel(BtunRole role) => switch (role) {
    BtunRole.client => 'Relay public key',
    BtunRole.relay => 'Client public key',
  };

  String _peerKeyPlaceholder(BtunRole role) => switch (role) {
    BtunRole.client => 'RELAY_PUBLIC_KEY',
    BtunRole.relay => 'CLIENT_PUBLIC_KEY',
  };

  Future<String> promptString(
    String label, {
    required String defaultValue,
    String? help,
    bool allowEmpty = false,
  }) {
    return _prompt<String>(
      label,
      defaultText: defaultValue,
      help: help,
      parse: (input) {
        if (input.isEmpty) return defaultValue;
        if (input.trim().isEmpty && !allowEmpty) {
          throw const FormatException('enter text or press Enter for default');
        }
        return input.trim();
      },
    );
  }

  Future<BtunRole> promptRole(
    String label, {
    required BtunRole defaultValue,
    String? help,
  }) {
    return _prompt<BtunRole>(
      label,
      defaultText: defaultValue.name,
      help: help,
      parse: (input) {
        final value = input.isEmpty ? defaultValue.name : input.toLowerCase();
        return switch (value) {
          'relay' => BtunRole.relay,
          'client' => BtunRole.client,
          _ => throw const FormatException('enter one of: client, relay'),
        };
      },
    );
  }

  Future<BtunTransportPreset> promptTransportPreset(
    String label, {
    required BtunTransportPreset defaultValue,
    String? help,
  }) {
    return _prompt<BtunTransportPreset>(
      label,
      defaultText: defaultValue.name,
      help: help,
      parse: (input) => parseTransportPreset(input, defaultValue: defaultValue),
    );
  }

  Future<bool> promptBool(
    String label, {
    required bool defaultValue,
    String? help,
  }) {
    return _prompt<bool>(
      label,
      defaultText: defaultValue ? 'yes' : 'no',
      help: help,
      parse: (input) => parseBool(input, defaultValue: defaultValue),
    );
  }

  Future<int> promptInt(
    String label, {
    required int defaultValue,
    int? min,
    int? max,
    String? help,
  }) {
    return _prompt<int>(
      label,
      defaultText: defaultValue.toString(),
      help: help,
      parse: (input) =>
          parseInt(input, defaultValue: defaultValue, min: min, max: max),
    );
  }

  Future<List<int>> promptPortList(
    String label, {
    required List<int> defaultValue,
    String? help,
  }) {
    return _prompt<List<int>>(
      label,
      defaultText: defaultValue.join(','),
      help: help,
      parse: (input) => parsePortList(input, defaultValue: defaultValue),
    );
  }

  Future<T> _prompt<T>(
    String label, {
    required String defaultText,
    required T Function(String input) parse,
    String? help,
  }) async {
    while (true) {
      write('$label [$defaultText]: ');
      final line = readLine();
      if (line == null) throw const FormatException('input closed');
      final input = line.trim();
      if (input == '?') {
        writeln(help ?? 'Press Enter to accept the default.');
        continue;
      }
      try {
        return parse(input);
      } on FormatException catch (error) {
        writeln('Invalid input: ${error.message}.');
      }
    }
  }
}

bool parseBool(String input, {required bool defaultValue}) {
  final value = input.trim().toLowerCase();
  if (value.isEmpty) return defaultValue;
  if (value == 'y' || value == 'yes' || value == 'true') return true;
  if (value == 'n' || value == 'no' || value == 'false') return false;
  throw const FormatException('enter y/n, yes/no, or true/false');
}

BtunTransportPreset parseTransportPreset(
  String input, {
  required BtunTransportPreset defaultValue,
}) {
  final value = input.trim().toLowerCase();
  if (value.isEmpty) return defaultValue;
  return switch (value) {
    '1' ||
    'interactive' ||
    'i' ||
    'responsive' ||
    'fast' => BtunTransportPreset.interactive,
    '2' ||
    'stable' ||
    's' ||
    'balanced' ||
    'balance' ||
    'medium' => BtunTransportPreset.stable,
    '3' ||
    'resilient' ||
    'r' ||
    'conservative' ||
    'slow' => BtunTransportPreset.resilient,
    '4' || 'custom' => BtunTransportPreset.custom,
    _ => throw const FormatException(
      'enter 1, 2, 3, 4, or one of: interactive, stable, resilient, custom',
    ),
  };
}

int parseInt(String input, {required int defaultValue, int? min, int? max}) {
  final value = input.trim();
  final parsed = value.isEmpty ? defaultValue : int.tryParse(value);
  if (parsed == null) throw const FormatException('enter an integer');
  if (min != null && parsed < min) {
    throw FormatException('enter an integer >= $min');
  }
  if (max != null && parsed > max) {
    throw FormatException('enter an integer <= $max');
  }
  return parsed;
}

List<int> parsePortList(String input, {required List<int> defaultValue}) {
  final value = input.trim();
  if (value.isEmpty) return List<int>.of(defaultValue);
  final ports = <int>[];
  for (final part in value.split(',')) {
    final port = int.tryParse(part.trim());
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException(
        'enter comma-separated ports from 1 to 65535',
      );
    }
    ports.add(port);
  }
  if (ports.isEmpty) {
    throw const FormatException('enter at least one port');
  }
  return ports;
}
