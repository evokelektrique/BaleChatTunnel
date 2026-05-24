import 'dart:convert';
import 'dart:io';
import 'dart:math';

enum BtunRole { client, relay }

class BtunAdaptiveConfig {
  const BtunAdaptiveConfig({
    required this.minPollInterval,
    required this.maxPollInterval,
    required this.minAckFlushInterval,
    required this.maxAckFlushInterval,
    required this.minFlushDelay,
    required this.maxFlushDelay,
    required this.minUploadRatePerMinute,
    required this.maxUploadRatePerMinute,
    required this.minChunkSize,
    required this.maxChunkSize,
    required this.maxInFlight,
    required this.maxStreams,
  });

  final Duration minPollInterval;
  final Duration maxPollInterval;
  final Duration minAckFlushInterval;
  final Duration maxAckFlushInterval;
  final Duration minFlushDelay;
  final Duration maxFlushDelay;
  final int minUploadRatePerMinute;
  final int maxUploadRatePerMinute;
  final int minChunkSize;
  final int maxChunkSize;
  final int maxInFlight;
  final int maxStreams;

  static const defaults = BtunAdaptiveConfig(
    minPollInterval: Duration(milliseconds: 1000),
    maxPollInterval: Duration(milliseconds: 4000),
    minAckFlushInterval: Duration(milliseconds: 200),
    maxAckFlushInterval: Duration(milliseconds: 500),
    minFlushDelay: Duration(milliseconds: 50),
    maxFlushDelay: Duration(milliseconds: 250),
    minUploadRatePerMinute: 10,
    maxUploadRatePerMinute: 50,
    minChunkSize: 64 * 1024,
    maxChunkSize: 1024 * 1024,
    maxInFlight: 1,
    maxStreams: 8,
  );

  static BtunAdaptiveConfig fromJson(Map<String, Object?>? json) {
    if (json == null) return defaults;
    return defaults.copyWith(
      minPollInterval: _duration(json['min_poll_interval_ms']),
      maxPollInterval: _duration(json['max_poll_interval_ms']),
      minAckFlushInterval: _duration(json['min_ack_flush_interval_ms']),
      maxAckFlushInterval: _duration(json['max_ack_flush_interval_ms']),
      minFlushDelay: _duration(json['min_flush_delay_ms']),
      maxFlushDelay: _duration(json['max_flush_delay_ms']),
      minUploadRatePerMinute: json['min_upload_rate_per_minute'] as int?,
      maxUploadRatePerMinute: json['max_upload_rate_per_minute'] as int?,
      minChunkSize: json['min_chunk_size'] as int?,
      maxChunkSize: json['max_chunk_size'] as int?,
      maxInFlight: json['max_in_flight'] as int?,
      maxStreams: json['max_streams'] as int?,
    );
  }

  Map<String, Object?> toJson() => {
    'min_poll_interval_ms': minPollInterval.inMilliseconds,
    'max_poll_interval_ms': maxPollInterval.inMilliseconds,
    'min_ack_flush_interval_ms': minAckFlushInterval.inMilliseconds,
    'max_ack_flush_interval_ms': maxAckFlushInterval.inMilliseconds,
    'min_flush_delay_ms': minFlushDelay.inMilliseconds,
    'max_flush_delay_ms': maxFlushDelay.inMilliseconds,
    'min_upload_rate_per_minute': minUploadRatePerMinute,
    'max_upload_rate_per_minute': maxUploadRatePerMinute,
    'min_chunk_size': minChunkSize,
    'max_chunk_size': maxChunkSize,
    'max_in_flight': maxInFlight,
    'max_streams': maxStreams,
  };

  BtunAdaptiveConfig copyWith({
    Duration? minPollInterval,
    Duration? maxPollInterval,
    Duration? minAckFlushInterval,
    Duration? maxAckFlushInterval,
    Duration? minFlushDelay,
    Duration? maxFlushDelay,
    int? minUploadRatePerMinute,
    int? maxUploadRatePerMinute,
    int? minChunkSize,
    int? maxChunkSize,
    int? maxInFlight,
    int? maxStreams,
  }) => BtunAdaptiveConfig(
    minPollInterval: minPollInterval ?? this.minPollInterval,
    maxPollInterval: maxPollInterval ?? this.maxPollInterval,
    minAckFlushInterval: minAckFlushInterval ?? this.minAckFlushInterval,
    maxAckFlushInterval: maxAckFlushInterval ?? this.maxAckFlushInterval,
    minFlushDelay: minFlushDelay ?? this.minFlushDelay,
    maxFlushDelay: maxFlushDelay ?? this.maxFlushDelay,
    minUploadRatePerMinute:
        minUploadRatePerMinute ?? this.minUploadRatePerMinute,
    maxUploadRatePerMinute:
        maxUploadRatePerMinute ?? this.maxUploadRatePerMinute,
    minChunkSize: minChunkSize ?? this.minChunkSize,
    maxChunkSize: maxChunkSize ?? this.maxChunkSize,
    maxInFlight: maxInFlight ?? this.maxInFlight,
    maxStreams: maxStreams ?? this.maxStreams,
  );

  static Duration? _duration(Object? value) =>
      value is int ? Duration(milliseconds: value) : null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BtunAdaptiveConfig &&
          minPollInterval == other.minPollInterval &&
          maxPollInterval == other.maxPollInterval &&
          minAckFlushInterval == other.minAckFlushInterval &&
          maxAckFlushInterval == other.maxAckFlushInterval &&
          minFlushDelay == other.minFlushDelay &&
          maxFlushDelay == other.maxFlushDelay &&
          minUploadRatePerMinute == other.minUploadRatePerMinute &&
          maxUploadRatePerMinute == other.maxUploadRatePerMinute &&
          minChunkSize == other.minChunkSize &&
          maxChunkSize == other.maxChunkSize &&
          maxInFlight == other.maxInFlight &&
          maxStreams == other.maxStreams;

  @override
  int get hashCode => Object.hash(
    minPollInterval,
    maxPollInterval,
    minAckFlushInterval,
    maxAckFlushInterval,
    minFlushDelay,
    maxFlushDelay,
    minUploadRatePerMinute,
    maxUploadRatePerMinute,
    minChunkSize,
    maxChunkSize,
    maxInFlight,
    maxStreams,
  );
}

class BtunConfig {
  const BtunConfig({
    required this.role,
    required this.accounts,
    required this.database,
    required this.sessionId,
    required this.localPublicKey,
    required this.localPrivateKey,
    required this.peerPublicKey,
    required this.socksHost,
    required this.socksPort,
    required this.adaptive,
    required this.retryTimeout,
    required this.maxRetryChunks,
    required this.maxRetryBytes,
  });

  final BtunRole role;
  final List<BtunAccountConfig> accounts;
  final String database;
  final String sessionId;
  final String localPublicKey;
  final String localPrivateKey;
  final String? peerPublicKey;
  final String socksHost;
  final int socksPort;
  final BtunAdaptiveConfig adaptive;
  final Duration retryTimeout;
  final int maxRetryChunks;
  final int maxRetryBytes;

  int get chunkSize => adaptive.minChunkSize;
  int get bulkChunkSize => adaptive.maxChunkSize;
  int get maxInFlight => adaptive.maxInFlight;
  Duration get pollInterval => adaptive.minPollInterval;
  Duration get uploadMinInterval => Duration.zero;
  int get uploadRateLimitPerMinute => adaptive.maxUploadRatePerMinute;
  Duration get ackFlushInterval => adaptive.minAckFlushInterval;
  Duration get maxAckFlushInterval => adaptive.maxAckFlushInterval;
  Duration get flushDelay => adaptive.minFlushDelay;
  Duration get bulkFlushDelay => adaptive.maxFlushDelay;
  int get maxStreams => adaptive.maxStreams;

  static String defaultProfileDir() => '.btun';
  static String defaultConfigPath(String profileDir) =>
      '$profileDir/config.json';
  static String defaultAccountsDir(String profileDir) => '$profileDir/accounts';
  static String accountSessionPath(String profileDir, int userId) =>
      '${defaultAccountsDir(profileDir)}/$userId.session.json';
  static String defaultDatabasePath(String profileDir) =>
      '$profileDir/state.json';

  static BtunConfig defaults({String profileDir = '.btun'}) => BtunConfig(
    role: BtunRole.client,
    accounts: const [],
    database: defaultDatabasePath(profileDir),
    sessionId: randomSessionId(),
    localPublicKey: '',
    localPrivateKey: '',
    peerPublicKey: null,
    socksHost: '127.0.0.1',
    socksPort: 1080,
    adaptive: BtunAdaptiveConfig.defaults,
    retryTimeout: const Duration(milliseconds: 120000),
    maxRetryChunks: 64,
    maxRetryBytes: 64 * 1024 * 1024,
  );

  static String randomSessionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(4, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<BtunConfig?> tryLoad(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return load(path);
  }

  static Future<BtunConfig> load(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('missing config at $path; run btun init first');
    }
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, Object?>) {
      throw const FormatException('config must be a JSON object');
    }
    return fromJson(json);
  }

  static BtunConfig fromJson(Map<String, Object?> json) {
    final retryMs = json['retry_timeout_ms'] as int?;
    return BtunConfig(
      role: _role(json['role'] as String? ?? 'client'),
      accounts: [
        for (final account in json['accounts'] as List? ?? const [])
          BtunAccountConfig.fromJson(account as Map<String, Object?>),
      ],
      database: json['database'] as String,
      sessionId: json['session_id'] as String,
      localPublicKey: json['local_public_key'] as String? ?? '',
      localPrivateKey: json['local_private_key'] as String? ?? '',
      peerPublicKey: json['peer_public_key'] as String?,
      socksHost: json['socks_host'] as String? ?? '127.0.0.1',
      socksPort: json['socks_port'] as int? ?? 1080,
      adaptive: BtunAdaptiveConfig.fromJson(
        json['adaptive'] as Map<String, Object?>?,
      ),
      retryTimeout: Duration(milliseconds: retryMs ?? 120000),
      maxRetryChunks: json['max_retry_chunks'] as int? ?? 64,
      maxRetryBytes: json['max_retry_bytes'] as int? ?? 64 * 1024 * 1024,
    );
  }

  Future<void> save(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
    if (!Platform.isWindows && !Platform.isAndroid) {
      await Process.run('chmod', ['600', file.path]);
    }
  }

  Map<String, Object?> toJson() => {
    'role': role.name,
    'accounts': [for (final account in accounts) account.toJson()],
    'database': database,
    'session_id': sessionId,
    'local_public_key': localPublicKey,
    'local_private_key': localPrivateKey,
    'peer_public_key': peerPublicKey,
    'socks_host': socksHost,
    'socks_port': socksPort,
    'adaptive': adaptive.toJson(),
    'retry_timeout_ms': retryTimeout.inMilliseconds,
    'max_retry_chunks': maxRetryChunks,
    'max_retry_bytes': maxRetryBytes,
  };

  BtunConfig copyWith({
    BtunRole? role,
    List<BtunAccountConfig>? accounts,
    String? database,
    String? sessionId,
    String? localPublicKey,
    String? localPrivateKey,
    String? peerPublicKey,
    String? socksHost,
    int? socksPort,
    BtunAdaptiveConfig? adaptive,
    Duration? retryTimeout,
    int? maxRetryChunks,
    int? maxRetryBytes,
    int? maxStreams,
    int? maxInFlight,
    int? chunkSize,
    int? bulkChunkSize,
    Duration? pollInterval,
    Duration? uploadMinInterval,
    int? uploadRateLimitPerMinute,
    Duration? ackFlushInterval,
    Duration? flushDelay,
    Duration? bulkFlushDelay,
  }) {
    final nextAdaptive = (adaptive ?? this.adaptive).copyWith(
      minChunkSize: chunkSize,
      maxChunkSize: bulkChunkSize,
      maxInFlight: maxInFlight,
      minPollInterval: pollInterval,
      maxUploadRatePerMinute: uploadRateLimitPerMinute,
      minAckFlushInterval: ackFlushInterval,
      minFlushDelay: flushDelay,
      maxFlushDelay: bulkFlushDelay,
      maxStreams: maxStreams,
    );
    return BtunConfig(
      role: role ?? this.role,
      accounts: accounts ?? this.accounts,
      database: database ?? this.database,
      sessionId: sessionId ?? this.sessionId,
      localPublicKey: localPublicKey ?? this.localPublicKey,
      localPrivateKey: localPrivateKey ?? this.localPrivateKey,
      peerPublicKey: peerPublicKey ?? this.peerPublicKey,
      socksHost: socksHost ?? this.socksHost,
      socksPort: socksPort ?? this.socksPort,
      adaptive: nextAdaptive,
      retryTimeout: retryTimeout ?? this.retryTimeout,
      maxRetryChunks: maxRetryChunks ?? this.maxRetryChunks,
      maxRetryBytes: maxRetryBytes ?? this.maxRetryBytes,
    );
  }

  List<BtunAccountConfig> get enabledAccounts =>
      accounts.where((account) => account.enabled).toList(growable: false);

  BtunConfig upsertAccount(BtunAccountConfig account) {
    final next = <BtunAccountConfig>[];
    var replaced = false;
    for (final existing in accounts) {
      if (existing.userId == account.userId) {
        next.add(account);
        replaced = true;
      } else {
        next.add(existing);
      }
    }
    if (!replaced) next.add(account);
    return copyWith(accounts: next);
  }

  BtunConfig removeAccount(int userId) => copyWith(
    accounts: accounts
        .where((account) => account.userId != userId)
        .toList(growable: false),
  );

  BtunConfig setAccountEnabled(int userId, bool enabled) => copyWith(
    accounts: [
      for (final account in accounts)
        account.userId == userId ? account.copyWith(enabled: enabled) : account,
    ],
  );

  static BtunRole _role(String value) => switch (value) {
    'relay' => BtunRole.relay,
    _ => BtunRole.client,
  };
}

class BtunAccountConfig {
  const BtunAccountConfig({
    required this.userId,
    required this.sessionFile,
    this.enabled = true,
  });

  final int userId;
  final String sessionFile;
  final bool enabled;

  static BtunAccountConfig fromJson(Map<String, Object?> json) =>
      BtunAccountConfig(
        userId: json['user_id'] as int,
        sessionFile: json['session_file'] as String,
        enabled: json['enabled'] as bool? ?? true,
      );

  Map<String, Object?> toJson() => {
    'user_id': userId,
    'session_file': sessionFile,
    'enabled': enabled,
  };

  BtunAccountConfig copyWith({
    int? userId,
    String? sessionFile,
    bool? enabled,
  }) => BtunAccountConfig(
    userId: userId ?? this.userId,
    sessionFile: sessionFile ?? this.sessionFile,
    enabled: enabled ?? this.enabled,
  );
}
