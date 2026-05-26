import 'dart:convert';
import 'dart:io';

/// Small JSON state store for transport deduplication and stream diagnostics.
class StateDb {
  StateDb._(this._file, this._state);

  final File _file;
  final _StateSnapshot _state;

  static StateDb open(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    if (!file.existsSync()) {
      final state = _StateSnapshot.empty();
      final db = StateDb._(file, state);
      db._flush();
      return db;
    }
    final raw = file.readAsStringSync();
    if (raw.trim().isEmpty) {
      return StateDb._(file, _StateSnapshot.empty());
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return StateDb._(file, _StateSnapshot.fromJson(decoded));
      }
    } on FormatException {
      // Older MVP configs used a .sqlite extension. If that file is invalid for
      // the JSON state store, start fresh instead of making local testing hard.
    }
    final db = StateDb._(file, _StateSnapshot.empty());
    db._flush();
    return db;
  }

  bool hasProcessedMessage(String messageId) {
    // Bale history polling can replay old documents. Message IDs prevent
    // downloading the same tunnel file more than once.
    return _state.processedMessages.containsKey(messageId);
  }

  void markProcessedMessage(String messageId) {
    _state.processedMessages[messageId] = _now();
    _flush();
  }

  void upsertStream({
    required int streamId,
    required String host,
    required int port,
    required String status,
  }) {
    _state.streams[streamId.toString()] = _StreamRecord(
      streamId: streamId,
      host: host,
      port: port,
      status: status,
      createdAt: _now(),
    );
    _flush();
  }

  void closeStream(int streamId, String status) {
    final key = streamId.toString();
    final existing = _state.streams[key];
    if (existing == null) return;
    _state.streams[key] = existing.copyWith(status: status, closedAt: _now());
    _flush();
  }

  void close() => _flush();

  void _flush() {
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(_state.toJson()),
      flush: true,
    );
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;
}

class _StateSnapshot {
  _StateSnapshot({required this.processedMessages, required this.streams});

  final Map<String, int> processedMessages;
  final Map<String, _StreamRecord> streams;

  factory _StateSnapshot.empty() {
    return _StateSnapshot(processedMessages: {}, streams: {});
  }

  factory _StateSnapshot.fromJson(Map<String, Object?> json) {
    final streamsJson = json['streams'] as Map? ?? const {};
    return _StateSnapshot(
      processedMessages: _intMap(json['processed_messages']),
      streams: {
        for (final entry in streamsJson.entries)
          entry.key as String: _StreamRecord.fromJson(
            (entry.value as Map).cast<String, Object?>(),
          ),
      },
    );
  }

  Map<String, Object?> toJson() => {
    'processed_messages': processedMessages,
    'streams': {
      for (final entry in streams.entries) entry.key: entry.value.toJson(),
    },
  };

  static Map<String, int> _intMap(Object? value) {
    final raw = value as Map? ?? const {};
    return {
      for (final entry in raw.entries) entry.key as String: entry.value as int,
    };
  }
}

class _StreamRecord {
  const _StreamRecord({
    required this.streamId,
    required this.host,
    required this.port,
    required this.status,
    required this.createdAt,
    this.closedAt,
  });

  final int streamId;
  final String host;
  final int port;
  final String status;
  final int createdAt;
  final int? closedAt;

  _StreamRecord copyWith({String? status, int? closedAt}) {
    return _StreamRecord(
      streamId: streamId,
      host: host,
      port: port,
      status: status ?? this.status,
      createdAt: createdAt,
      closedAt: closedAt ?? this.closedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'stream_id': streamId,
    'host': host,
    'port': port,
    'status': status,
    'created_at': createdAt,
    'closed_at': closedAt,
  };

  static _StreamRecord fromJson(Map<String, Object?> json) {
    return _StreamRecord(
      streamId: json['stream_id'] as int,
      host: json['host'] as String,
      port: json['port'] as int,
      status: json['status'] as String,
      createdAt: json['created_at'] as int,
      closedAt: json['closed_at'] as int?,
    );
  }
}
