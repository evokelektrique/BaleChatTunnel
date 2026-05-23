import 'dart:convert';
import 'dart:io';
import 'dart:math';

enum BtunRole { client, relay }

enum BtunTransportPreset { interactive, stable, resilient, custom }

class BtunTransportPresetSpec {
  const BtunTransportPresetSpec({
    required this.preset,
    required this.label,
    required this.description,
    required this.chunkSize,
    required this.maxInFlight,
    required this.pollInterval,
    required this.uploadMinInterval,
    required this.uploadRateLimitPerMinute,
    required this.ackFlushInterval,
    required this.flushDelay,
    required this.bulkFlushDelay,
    required this.bulkChunkSize,
  });

  final BtunTransportPreset preset;
  final String label;
  final String description;
  final int chunkSize;
  final int maxInFlight;
  final Duration pollInterval;
  final Duration uploadMinInterval;
  final int uploadRateLimitPerMinute;
  final Duration ackFlushInterval;
  final Duration flushDelay;
  final Duration bulkFlushDelay;
  final int bulkChunkSize;

  bool matches(BtunConfig config) =>
      config.chunkSize == chunkSize &&
      config.maxInFlight == maxInFlight &&
      config.pollInterval == pollInterval &&
      config.uploadMinInterval == uploadMinInterval &&
      config.uploadRateLimitPerMinute == uploadRateLimitPerMinute &&
      config.ackFlushInterval == ackFlushInterval &&
      config.flushDelay == flushDelay &&
      config.bulkFlushDelay == bulkFlushDelay &&
      config.bulkChunkSize == bulkChunkSize;
}

const btunTransportPresetSpecs = {
  BtunTransportPreset.interactive: BtunTransportPresetSpec(
    preset: BtunTransportPreset.interactive,
    label: 'Interactive',
    description: 'Lower latency with higher Bale rate-limit risk.',
    chunkSize: 64 * 1024,
    maxInFlight: 4,
    pollInterval: Duration(milliseconds: 500),
    uploadMinInterval: Duration.zero,
    uploadRateLimitPerMinute: 50,
    ackFlushInterval: Duration(milliseconds: 100),
    flushDelay: Duration.zero,
    bulkFlushDelay: Duration(milliseconds: 50),
    bulkChunkSize: 512 * 1024,
  ),
  BtunTransportPreset.stable: BtunTransportPresetSpec(
    preset: BtunTransportPreset.stable,
    label: 'Stable',
    description: 'Balanced cadence for proxied messaging.',
    chunkSize: 256 * 1024,
    maxInFlight: 2,
    pollInterval: Duration(milliseconds: 3000),
    uploadMinInterval: Duration.zero,
    uploadRateLimitPerMinute: 40,
    ackFlushInterval: Duration(milliseconds: 1000),
    flushDelay: Duration(milliseconds: 100),
    bulkFlushDelay: Duration(milliseconds: 250),
    bulkChunkSize: 512 * 1024,
  ),
  BtunTransportPreset.resilient: BtunTransportPresetSpec(
    preset: BtunTransportPreset.resilient,
    label: 'Resilient',
    description: 'Safest cadence with the fewest regular uploads.',
    chunkSize: 256 * 1024,
    maxInFlight: 2,
    pollInterval: Duration(milliseconds: 2000),
    uploadMinInterval: Duration(milliseconds: 500),
    uploadRateLimitPerMinute: 35,
    ackFlushInterval: Duration(milliseconds: 500),
    flushDelay: Duration(milliseconds: 100),
    bulkFlushDelay: Duration(milliseconds: 300),
    bulkChunkSize: 2 * 1024 * 1024,
  ),
};

class BtunConfig {
  const BtunConfig({
    required this.role,
    required this.sessionFile,
    required this.database,
    required this.sessionId,
    required this.localPublicKey,
    required this.localPrivateKey,
    required this.peerPublicKey,
    required this.socksHost,
    required this.socksPort,
    required this.chunkSize,
    required this.maxInFlight,
    required this.pollInterval,
    required this.retryTimeout,
    required this.uploadMinInterval,
    required this.uploadRateLimitPerMinute,
    required this.ackFlushInterval,
    required this.flushDelay,
    required this.bulkFlushDelay,
    required this.bulkChunkSize,
    required this.transportPreset,
    required this.maxRetryChunks,
    required this.maxRetryBytes,
    required this.maxStreams,
    required this.allowPorts,
    required this.blockPrivateIps,
    required this.dnsOnRelay,
  });

  final BtunRole role;
  final String sessionFile;
  final String database;
  final String sessionId;
  final String localPublicKey;
  final String localPrivateKey;
  final String? peerPublicKey;
  final String socksHost;
  final int socksPort;
  final int chunkSize;
  final int maxInFlight;
  final Duration pollInterval;
  final Duration retryTimeout;
  final Duration uploadMinInterval;
  final int uploadRateLimitPerMinute;
  final Duration ackFlushInterval;
  final Duration flushDelay;
  final Duration bulkFlushDelay;
  final int bulkChunkSize;
  final BtunTransportPreset transportPreset;
  final int maxRetryChunks;
  final int maxRetryBytes;
  final int maxStreams;
  final List<int> allowPorts;
  final bool blockPrivateIps;
  final bool dnsOnRelay;

  static String defaultProfileDir() => '.btun';
  static String defaultConfigPath(String profileDir) =>
      '$profileDir/config.json';
  static String defaultSessionPath(String profileDir) =>
      '$profileDir/session.json';
  static String defaultDatabasePath(String profileDir) =>
      '$profileDir/state.json';

  static BtunConfig defaults({String profileDir = '.btun'}) {
    final preset = btunTransportPresetSpecs[BtunTransportPreset.stable]!;
    return BtunConfig(
      role: BtunRole.client,
      sessionFile: defaultSessionPath(profileDir),
      database: defaultDatabasePath(profileDir),
      sessionId: randomSessionId(),
      localPublicKey: '',
      localPrivateKey: '',
      peerPublicKey: null,
      socksHost: '127.0.0.1',
      socksPort: 1080,
      chunkSize: preset.chunkSize,
      maxInFlight: preset.maxInFlight,
      pollInterval: preset.pollInterval,
      retryTimeout: const Duration(milliseconds: 120000),
      uploadMinInterval: preset.uploadMinInterval,
      uploadRateLimitPerMinute: preset.uploadRateLimitPerMinute,
      ackFlushInterval: preset.ackFlushInterval,
      flushDelay: preset.flushDelay,
      bulkFlushDelay: preset.bulkFlushDelay,
      bulkChunkSize: preset.bulkChunkSize,
      transportPreset: BtunTransportPreset.stable,
      maxRetryChunks: 64,
      maxRetryBytes: 64 * 1024 * 1024,
      maxStreams: 4,
      allowPorts: const [80, 443],
      blockPrivateIps: true,
      dnsOnRelay: true,
    );
  }

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
    final stable = btunTransportPresetSpecs[BtunTransportPreset.stable]!;
    final relay = json['relay'] is Map<String, Object?>
        ? json['relay']! as Map<String, Object?>
        : const <String, Object?>{};
    final configuredChunkSize = json['chunk_size'] as int?;
    final configuredPollMs = json['poll_interval_ms'] as int?;
    final configuredRetryMs = json['retry_timeout_ms'] as int?;
    final configuredUploadIntervalMs = json['upload_min_interval_ms'] as int?;
    final configuredUploadRateLimit =
        json['upload_rate_limit_per_minute'] as int?;
    final configuredAckFlushMs = json['ack_flush_interval_ms'] as int?;
    final configuredFlushDelayMs = json['flush_delay_ms'] as int?;
    final configuredBulkFlushDelayMs = json['bulk_flush_delay_ms'] as int?;
    final configuredBulkChunkSize = json['bulk_chunk_size'] as int?;
    final configuredMaxRetryChunks = json['max_retry_chunks'] as int?;
    final configuredMaxRetryBytes = json['max_retry_bytes'] as int?;
    final config = BtunConfig(
      role: _role(json['role'] as String? ?? 'client'),
      sessionFile: json['session_file'] as String,
      database: json['database'] as String,
      sessionId: json['session_id'] as String,
      localPublicKey: json['local_public_key'] as String? ?? '',
      localPrivateKey: json['local_private_key'] as String? ?? '',
      peerPublicKey: json['peer_public_key'] as String?,
      socksHost: json['socks_host'] as String? ?? '127.0.0.1',
      socksPort: json['socks_port'] as int? ?? 1080,
      chunkSize: configuredChunkSize ?? stable.chunkSize,
      maxInFlight: json['max_in_flight'] as int? ?? stable.maxInFlight,
      pollInterval: Duration(
        milliseconds: configuredPollMs ?? stable.pollInterval.inMilliseconds,
      ),
      retryTimeout: Duration(
        milliseconds:
            configuredRetryMs == null ||
                configuredRetryMs == 20000 ||
                configuredRetryMs == 60000
            ? 120000
            : configuredRetryMs,
      ),
      uploadMinInterval: Duration(
        milliseconds:
            configuredUploadIntervalMs ??
            stable.uploadMinInterval.inMilliseconds,
      ),
      uploadRateLimitPerMinute:
          configuredUploadRateLimit == null || configuredUploadRateLimit == 45
          ? stable.uploadRateLimitPerMinute
          : configuredUploadRateLimit,
      ackFlushInterval: Duration(
        milliseconds:
            configuredAckFlushMs ?? stable.ackFlushInterval.inMilliseconds,
      ),
      flushDelay: Duration(
        milliseconds:
            configuredFlushDelayMs ?? stable.flushDelay.inMilliseconds,
      ),
      bulkFlushDelay: Duration(
        milliseconds:
            configuredBulkFlushDelayMs ?? stable.bulkFlushDelay.inMilliseconds,
      ),
      bulkChunkSize: configuredBulkChunkSize ?? stable.bulkChunkSize,
      transportPreset: _transportPreset(json['transport_preset'] as String?),
      maxRetryChunks: configuredMaxRetryChunks ?? 64,
      maxRetryBytes: configuredMaxRetryBytes ?? 64 * 1024 * 1024,
      maxStreams: json['max_streams'] as int? ?? 4,
      allowPorts: [
        for (final port in relay['allow_ports'] as List? ?? const [80, 443])
          port as int,
      ],
      blockPrivateIps: relay['block_private_ips'] as bool? ?? true,
      dnsOnRelay: relay['dns_on_relay'] as bool? ?? true,
    );
    return config.copyWith(transportPreset: _detectTransportPreset(config));
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
    'session_file': sessionFile,
    'database': database,
    'session_id': sessionId,
    'local_public_key': localPublicKey,
    'local_private_key': localPrivateKey,
    'peer_public_key': peerPublicKey,
    'socks_host': socksHost,
    'socks_port': socksPort,
    'chunk_size': chunkSize,
    'max_in_flight': maxInFlight,
    'poll_interval_ms': pollInterval.inMilliseconds,
    'retry_timeout_ms': retryTimeout.inMilliseconds,
    'upload_min_interval_ms': uploadMinInterval.inMilliseconds,
    'upload_rate_limit_per_minute': uploadRateLimitPerMinute,
    'ack_flush_interval_ms': ackFlushInterval.inMilliseconds,
    'flush_delay_ms': flushDelay.inMilliseconds,
    'bulk_flush_delay_ms': bulkFlushDelay.inMilliseconds,
    'bulk_chunk_size': bulkChunkSize,
    'transport_preset': _detectTransportPreset(this).name,
    'max_retry_chunks': maxRetryChunks,
    'max_retry_bytes': maxRetryBytes,
    'max_streams': maxStreams,
    'relay': {
      'allow_ports': allowPorts,
      'block_private_ips': blockPrivateIps,
      'dns_on_relay': dnsOnRelay,
    },
  };

  BtunConfig copyWith({
    BtunRole? role,
    String? sessionFile,
    String? database,
    String? sessionId,
    String? localPublicKey,
    String? localPrivateKey,
    String? peerPublicKey,
    String? socksHost,
    int? socksPort,
    int? chunkSize,
    int? maxInFlight,
    Duration? pollInterval,
    Duration? retryTimeout,
    Duration? uploadMinInterval,
    int? uploadRateLimitPerMinute,
    Duration? ackFlushInterval,
    Duration? flushDelay,
    Duration? bulkFlushDelay,
    int? bulkChunkSize,
    BtunTransportPreset? transportPreset,
    int? maxRetryChunks,
    int? maxRetryBytes,
    int? maxStreams,
    List<int>? allowPorts,
    bool? blockPrivateIps,
    bool? dnsOnRelay,
  }) => BtunConfig(
    role: role ?? this.role,
    sessionFile: sessionFile ?? this.sessionFile,
    database: database ?? this.database,
    sessionId: sessionId ?? this.sessionId,
    localPublicKey: localPublicKey ?? this.localPublicKey,
    localPrivateKey: localPrivateKey ?? this.localPrivateKey,
    peerPublicKey: peerPublicKey ?? this.peerPublicKey,
    socksHost: socksHost ?? this.socksHost,
    socksPort: socksPort ?? this.socksPort,
    chunkSize: chunkSize ?? this.chunkSize,
    maxInFlight: maxInFlight ?? this.maxInFlight,
    pollInterval: pollInterval ?? this.pollInterval,
    retryTimeout: retryTimeout ?? this.retryTimeout,
    uploadMinInterval: uploadMinInterval ?? this.uploadMinInterval,
    uploadRateLimitPerMinute:
        uploadRateLimitPerMinute ?? this.uploadRateLimitPerMinute,
    ackFlushInterval: ackFlushInterval ?? this.ackFlushInterval,
    flushDelay: flushDelay ?? this.flushDelay,
    bulkFlushDelay: bulkFlushDelay ?? this.bulkFlushDelay,
    bulkChunkSize: bulkChunkSize ?? this.bulkChunkSize,
    transportPreset: transportPreset ?? this.transportPreset,
    maxRetryChunks: maxRetryChunks ?? this.maxRetryChunks,
    maxRetryBytes: maxRetryBytes ?? this.maxRetryBytes,
    maxStreams: maxStreams ?? this.maxStreams,
    allowPorts: allowPorts ?? this.allowPorts,
    blockPrivateIps: blockPrivateIps ?? this.blockPrivateIps,
    dnsOnRelay: dnsOnRelay ?? this.dnsOnRelay,
  );

  static BtunRole _role(String value) => switch (value) {
    'relay' => BtunRole.relay,
    _ => BtunRole.client,
  };

  static BtunTransportPreset _transportPreset(String? value) =>
      BtunTransportPreset.values.firstWhere(
        (preset) => preset.name == value,
        orElse: () => BtunTransportPreset.custom,
      );

  static BtunTransportPreset _detectTransportPreset(BtunConfig config) {
    for (final entry in btunTransportPresetSpecs.entries) {
      if (entry.value.matches(config)) return entry.key;
    }
    return BtunTransportPreset.custom;
  }

  BtunConfig applyTransportPreset(BtunTransportPreset preset) {
    final spec = btunTransportPresetSpecs[preset];
    if (spec == null) {
      return copyWith(transportPreset: BtunTransportPreset.custom);
    }
    return copyWith(
      chunkSize: spec.chunkSize,
      maxInFlight: spec.maxInFlight,
      pollInterval: spec.pollInterval,
      uploadMinInterval: spec.uploadMinInterval,
      uploadRateLimitPerMinute: spec.uploadRateLimitPerMinute,
      ackFlushInterval: spec.ackFlushInterval,
      flushDelay: spec.flushDelay,
      bulkFlushDelay: spec.bulkFlushDelay,
      bulkChunkSize: spec.bulkChunkSize,
      transportPreset: preset,
    );
  }
}
