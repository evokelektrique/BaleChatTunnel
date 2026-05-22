import 'dart:convert';
import 'dart:typed_data';

const _plainChunkMagic = 0x32505442; // BTP2
const _encryptedChunkMagic = 0x32455442; // BTE2
const _nullStringLength = 0xffff;

enum Direction {
  c2r,
  r2c;

  static Direction parse(String value) => switch (value) {
    'c2r' => Direction.c2r,
    'r2c' => Direction.r2c,
    _ => throw FormatException('invalid direction $value'),
  };
}

enum FrameType {
  hello,
  ready,
  open,
  data,
  ack,
  close,
  reset,
  ping,
  pong,
  error;

  static FrameType parse(String value) {
    for (final type in values) {
      if (type.name == value.toLowerCase()) return type;
    }
    throw FormatException('invalid frame type $value');
  }
}

class TunnelFrame {
  const TunnelFrame({
    required this.version,
    required this.sessionId,
    required this.direction,
    required this.streamId,
    required this.sequenceNumber,
    required this.ackNumber,
    required this.type,
    this.host,
    this.port,
    this.payload = const <int>[],
    this.message,
  });

  final int version;
  final String sessionId;
  final Direction direction;
  final int streamId;
  final int sequenceNumber;
  final int ackNumber;
  final FrameType type;
  final String? host;
  final int? port;
  final List<int> payload;
  final String? message;

  factory TunnelFrame.open({
    required String sessionId,
    required Direction direction,
    required int streamId,
    required int sequenceNumber,
    required String host,
    required int port,
  }) => TunnelFrame(
    version: 1,
    sessionId: sessionId,
    direction: direction,
    streamId: streamId,
    sequenceNumber: sequenceNumber,
    ackNumber: 0,
    type: FrameType.open,
    host: host,
    port: port,
  );

  factory TunnelFrame.data({
    required String sessionId,
    required Direction direction,
    required int streamId,
    required int sequenceNumber,
    required List<int> payload,
  }) => TunnelFrame(
    version: 1,
    sessionId: sessionId,
    direction: direction,
    streamId: streamId,
    sequenceNumber: sequenceNumber,
    ackNumber: 0,
    type: FrameType.data,
    payload: payload,
  );

  factory TunnelFrame.ack({
    required String sessionId,
    required Direction direction,
    required int ackNumber,
  }) => TunnelFrame(
    version: 1,
    sessionId: sessionId,
    direction: direction,
    streamId: 0,
    sequenceNumber: 0,
    ackNumber: ackNumber,
    type: FrameType.ack,
  );

  factory TunnelFrame.close({
    required String sessionId,
    required Direction direction,
    required int streamId,
    required int sequenceNumber,
  }) => TunnelFrame(
    version: 1,
    sessionId: sessionId,
    direction: direction,
    streamId: streamId,
    sequenceNumber: sequenceNumber,
    ackNumber: 0,
    type: FrameType.close,
  );

  factory TunnelFrame.reset({
    required String sessionId,
    required Direction direction,
    required int streamId,
    required int sequenceNumber,
    String? message,
  }) => TunnelFrame(
    version: 1,
    sessionId: sessionId,
    direction: direction,
    streamId: streamId,
    sequenceNumber: sequenceNumber,
    ackNumber: 0,
    type: FrameType.reset,
    message: message,
  );

  Map<String, Object?> toJson() => {
    'version': version,
    'session_id': sessionId,
    'direction': direction.name,
    'stream_id': streamId,
    'sequence_number': sequenceNumber,
    'ack_number': ackNumber,
    'type': type.name,
    'host': host,
    'port': port,
    'payload': base64Encode(payload),
    'payload_length': payload.length,
    'message': message,
  };

  static TunnelFrame fromJson(Map<String, Object?> json) {
    final payloadText = json['payload'] as String? ?? '';
    return TunnelFrame(
      version: json['version'] as int? ?? 1,
      sessionId: json['session_id'] as String,
      direction: Direction.parse(json['direction'] as String),
      streamId: json['stream_id'] as int? ?? 0,
      sequenceNumber: json['sequence_number'] as int? ?? 0,
      ackNumber: json['ack_number'] as int? ?? 0,
      type: FrameType.parse(json['type'] as String),
      host: json['host'] as String?,
      port: json['port'] as int?,
      payload: payloadText.isEmpty ? const [] : base64Decode(payloadText),
      message: json['message'] as String?,
    );
  }
}

class PlainChunk {
  const PlainChunk({
    required this.version,
    required this.sessionId,
    required this.direction,
    required this.sequenceNumber,
    required this.frames,
  });

  final int version;
  final String sessionId;
  final Direction direction;
  final int sequenceNumber;
  final List<TunnelFrame> frames;

  Uint8List encode() {
    final writer = _BinaryWriter()
      ..writeUint32(_plainChunkMagic)
      ..writeUint8(version)
      ..writeUint8(_directionId(direction))
      ..writeString(sessionId)
      ..writeUint64(sequenceNumber)
      ..writeUint32(frames.length);
    for (final frame in frames) {
      writer
        ..writeUint8(frame.version)
        ..writeUint8(_frameTypeId(frame.type))
        ..writeUint8(_directionId(frame.direction))
        ..writeUint64(frame.streamId)
        ..writeUint64(frame.sequenceNumber)
        ..writeUint64(frame.ackNumber)
        ..writeNullableString(frame.host)
        ..writeInt32(frame.port ?? -1)
        ..writeNullableString(frame.message)
        ..writeBytes(frame.payload);
    }
    return writer.takeBytes();
  }

  static PlainChunk decode(List<int> bytes) {
    if (_hasMagic(bytes, _plainChunkMagic)) {
      return _decodeBinary(bytes);
    }
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, Object?>) {
      throw const FormatException('chunk must be a JSON object');
    }
    final framesJson = json['frames'];
    if (framesJson is! List) {
      throw const FormatException('frames must be a list');
    }
    return PlainChunk(
      version: json['version'] as int? ?? 1,
      sessionId: json['session_id'] as String,
      direction: Direction.parse(json['direction'] as String),
      sequenceNumber: json['sequence_number'] as int,
      frames: [
        for (final item in framesJson)
          TunnelFrame.fromJson((item as Map).cast<String, Object?>()),
      ],
    );
  }

  static PlainChunk _decodeBinary(List<int> bytes) {
    final reader = _BinaryReader(bytes);
    reader.expectUint32(_plainChunkMagic);
    final version = reader.readUint8();
    final direction = _directionFromId(reader.readUint8());
    final sessionId = reader.readString();
    final sequenceNumber = reader.readUint64();
    final frameCount = reader.readUint32();
    final frames = <TunnelFrame>[];
    for (var i = 0; i < frameCount; i++) {
      final frameVersion = reader.readUint8();
      final type = _frameTypeFromId(reader.readUint8());
      final frameDirection = _directionFromId(reader.readUint8());
      final streamId = reader.readUint64();
      final frameSequence = reader.readUint64();
      final ackNumber = reader.readUint64();
      final host = reader.readNullableString();
      final port = reader.readInt32();
      final message = reader.readNullableString();
      final payload = reader.readBytes();
      frames.add(
        TunnelFrame(
          version: frameVersion,
          sessionId: sessionId,
          direction: frameDirection,
          streamId: streamId,
          sequenceNumber: frameSequence,
          ackNumber: ackNumber,
          type: type,
          host: host,
          port: port < 0 ? null : port,
          payload: payload,
          message: message,
        ),
      );
    }
    reader.expectDone();
    return PlainChunk(
      version: version,
      sessionId: sessionId,
      direction: direction,
      sequenceNumber: sequenceNumber,
      frames: frames,
    );
  }
}

class EncryptedChunkMetadata {
  const EncryptedChunkMetadata({
    required this.version,
    required this.sessionId,
    required this.direction,
    required this.sequenceNumber,
    required this.nonce,
    this.compressed = false,
  });

  final int version;
  final String sessionId;
  final Direction direction;
  final int sequenceNumber;
  final List<int> nonce;
  final bool compressed;

  List<int> aad() {
    if (version <= 1 && !compressed) {
      return utf8.encode(
        'btun|$version|$sessionId|${direction.name}|$sequenceNumber',
      );
    }
    return utf8.encode(
      'btun|$version|$sessionId|${direction.name}|$sequenceNumber|'
      '${compressed ? 1 : 0}',
    );
  }

  Map<String, Object?> toJson() => {
    'magic': 'btun',
    'version': version,
    'session_id': sessionId,
    'direction': direction.name,
    'sequence_number': sequenceNumber,
    'message_type': 'chunk',
    'nonce': base64Encode(nonce),
    'compressed': compressed,
  };

  static EncryptedChunkMetadata fromJson(Map<String, Object?> json) {
    if (json['magic'] != 'btun') throw const FormatException('not a btun file');
    if (json['message_type'] != 'chunk') {
      throw const FormatException('not a chunk file');
    }
    return EncryptedChunkMetadata(
      version: json['version'] as int? ?? 1,
      sessionId: json['session_id'] as String,
      direction: Direction.parse(json['direction'] as String),
      sequenceNumber: json['sequence_number'] as int,
      nonce: base64Decode(json['nonce'] as String),
      compressed: json['compressed'] as bool? ?? false,
    );
  }
}

class EncryptedChunkFile {
  const EncryptedChunkFile({
    required this.metadata,
    required this.cipherText,
    required this.mac,
  });

  final EncryptedChunkMetadata metadata;
  final List<int> cipherText;
  final List<int> mac;

  Uint8List encode() {
    return (_BinaryWriter()
          ..writeUint32(_encryptedChunkMagic)
          ..writeUint8(metadata.version)
          ..writeUint8(_directionId(metadata.direction))
          ..writeUint8(metadata.compressed ? 1 : 0)
          ..writeString(metadata.sessionId)
          ..writeUint64(metadata.sequenceNumber)
          ..writeBytes(metadata.nonce)
          ..writeBytes(mac)
          ..writeBytes(cipherText))
        .takeBytes();
  }

  static EncryptedChunkFile decode(List<int> bytes) {
    if (_hasMagic(bytes, _encryptedChunkMagic)) {
      return _decodeBinary(bytes);
    }
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, Object?>) {
      throw const FormatException('encrypted file must be JSON');
    }
    return EncryptedChunkFile(
      metadata: EncryptedChunkMetadata.fromJson(
        (json['metadata'] as Map).cast<String, Object?>(),
      ),
      cipherText: base64Decode(json['ciphertext'] as String),
      mac: base64Decode(json['mac'] as String),
    );
  }

  static EncryptedChunkFile _decodeBinary(List<int> bytes) {
    final reader = _BinaryReader(bytes);
    reader.expectUint32(_encryptedChunkMagic);
    final version = reader.readUint8();
    final direction = _directionFromId(reader.readUint8());
    final compressed = reader.readUint8() != 0;
    final sessionId = reader.readString();
    final sequenceNumber = reader.readUint64();
    final nonce = reader.readBytes();
    final mac = reader.readBytes();
    final cipherText = reader.readBytes();
    reader.expectDone();
    return EncryptedChunkFile(
      metadata: EncryptedChunkMetadata(
        version: version,
        sessionId: sessionId,
        direction: direction,
        sequenceNumber: sequenceNumber,
        nonce: nonce,
        compressed: compressed,
      ),
      cipherText: cipherText,
      mac: mac,
    );
  }
}

String btunFileName(String sessionId, Direction direction, int sequence) {
  return 'btun_${sessionId}_${direction.name}_${sequence.toString().padLeft(8, '0')}.bin';
}

bool isBtunFileName(String name) =>
    name.startsWith('btun_') && name.endsWith('.bin');

bool _hasMagic(List<int> bytes, int magic) {
  if (bytes.length < 4) return false;
  final data = Uint8List.fromList(bytes);
  return ByteData.sublistView(data).getUint32(0, Endian.little) == magic;
}

int _directionId(Direction direction) => switch (direction) {
  Direction.c2r => 0,
  Direction.r2c => 1,
};

Direction _directionFromId(int id) => switch (id) {
  0 => Direction.c2r,
  1 => Direction.r2c,
  _ => throw FormatException('invalid direction id $id'),
};

int _frameTypeId(FrameType type) => type.index;

FrameType _frameTypeFromId(int id) {
  if (id < 0 || id >= FrameType.values.length) {
    throw FormatException('invalid frame type id $id');
  }
  return FrameType.values[id];
}

class _BinaryWriter {
  final _bytes = BytesBuilder(copy: false);

  void writeUint8(int value) {
    _bytes.add([value & 0xff]);
  }

  void writeInt32(int value) {
    final data = ByteData(4)..setInt32(0, value, Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }

  void writeUint32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }

  void writeUint64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }

  void writeString(String value) {
    final bytes = utf8.encode(value);
    if (bytes.length >= _nullStringLength) {
      throw FormatException('string is too long: ${bytes.length}');
    }
    _writeUint16(bytes.length);
    _bytes.add(bytes);
  }

  void writeNullableString(String? value) {
    if (value == null) {
      _writeUint16(_nullStringLength);
      return;
    }
    writeString(value);
  }

  void writeBytes(List<int> value) {
    writeUint32(value.length);
    _bytes.add(value);
  }

  Uint8List takeBytes() => _bytes.takeBytes();

  void _writeUint16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    _bytes.add(data.buffer.asUint8List());
  }
}

class _BinaryReader {
  _BinaryReader(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  var _offset = 0;

  void expectUint32(int expected) {
    final actual = readUint32();
    if (actual != expected) {
      throw FormatException('invalid magic 0x${actual.toRadixString(16)}');
    }
  }

  int readUint8() {
    _require(1);
    return _bytes[_offset++];
  }

  int readInt32() {
    _require(4);
    final value = ByteData.sublistView(_bytes).getInt32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  int readUint32() {
    _require(4);
    final value = ByteData.sublistView(
      _bytes,
    ).getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  int readUint64() {
    _require(8);
    final value = ByteData.sublistView(
      _bytes,
    ).getUint64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  String readString() {
    final length = _readUint16();
    if (length == _nullStringLength) {
      throw const FormatException('unexpected null string');
    }
    return utf8.decode(_read(length));
  }

  String? readNullableString() {
    final length = _readUint16();
    if (length == _nullStringLength) return null;
    return utf8.decode(_read(length));
  }

  List<int> readBytes() {
    final length = readUint32();
    return _read(length);
  }

  void expectDone() {
    if (_offset != _bytes.length) {
      throw FormatException('trailing bytes: ${_bytes.length - _offset}');
    }
  }

  int _readUint16() {
    _require(2);
    final value = ByteData.sublistView(
      _bytes,
    ).getUint16(_offset, Endian.little);
    _offset += 2;
    return value;
  }

  List<int> _read(int length) {
    _require(length);
    final value = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return value;
  }

  void _require(int count) {
    if (count < 0 || _offset + count > _bytes.length) {
      throw const FormatException('truncated binary chunk');
    }
  }
}
