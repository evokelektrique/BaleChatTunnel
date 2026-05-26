import 'dart:convert';
import 'dart:typed_data';

const _plainChunkMagic = 0x32505442; // BTP2
const _encryptedChunkMagic = 0x32455442; // BTE2
const _nullStringLength = 0xffff;

/// File direction on the Bale Saved Messages transport.
enum Direction {
  c2r,
  r2c;

  static Direction parse(String value) => switch (value) {
    'c2r' => Direction.c2r,
    'r2c' => Direction.r2c,
    _ => throw FormatException('invalid direction $value'),
  };
}

/// Logical tunnel messages carried inside encrypted chunk files.
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

/// A single stream event inside the tunnel protocol.
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
    this.sackRanges = const <AckRange>[],
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
  final List<AckRange> sackRanges;

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
    List<AckRange> sackRanges = const <AckRange>[],
  }) => TunnelFrame(
    version: 1,
    sessionId: sessionId,
    direction: direction,
    streamId: 0,
    sequenceNumber: 0,
    ackNumber: ackNumber,
    type: FrameType.ack,
    sackRanges: sackRanges,
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
    'sack_ranges': [for (final range in sackRanges) range.toJson()],
  };

  static TunnelFrame fromJson(Map<String, Object?> json) {
    final payloadText = json['payload'] as String? ?? '';
    final sackRangesJson = json['sack_ranges'];
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
      sackRanges: [
        if (sackRangesJson is List)
          for (final item in sackRangesJson)
            AckRange.fromJson((item as Map).cast<String, Object?>()),
      ],
    );
  }
}

class AckRange {
  const AckRange({required this.start, required this.end});

  final int start;
  final int end;

  Map<String, Object?> toJson() => {'start': start, 'end': end};

  static AckRange fromJson(Map<String, Object?> json) =>
      AckRange(start: json['start'] as int, end: json['end'] as int);
}

/// A batch of frames before compression and encryption.
class PlainChunk {
  const PlainChunk({
    required this.version,
    required this.sessionId,
    required this.direction,
    required this.sequenceNumber,
    required this.frames,
    this.chunkEpoch,
    this.reliableSequenceNumber = 0,
    this.ackOnly = false,
  });

  final int version;
  final String sessionId;
  final Direction direction;
  final int sequenceNumber;
  final List<TunnelFrame> frames;
  final String? chunkEpoch;
  final int reliableSequenceNumber;
  final bool ackOnly;

  Uint8List encode() {
    if (version != 4) {
      throw FormatException('unsupported chunk version $version');
    }
    final chunkEpoch = this.chunkEpoch;
    if (chunkEpoch == null || chunkEpoch.isEmpty) {
      throw const FormatException('v4 chunks require a chunk epoch');
    }
    final writer = _BinaryWriter()
      ..writeUint32(_plainChunkMagic)
      ..writeUint8(version)
      ..writeUint8(_directionId(direction))
      ..writeString(sessionId)
      ..writeUint64(sequenceNumber)
      ..writeString(chunkEpoch)
      ..writeUint64(reliableSequenceNumber)
      ..writeUint8(ackOnly ? 1 : 0);
    writer.writeUint32(frames.length);
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
      writer.writeUint32(frame.sackRanges.length);
      for (final range in frame.sackRanges) {
        writer
          ..writeUint64(range.start)
          ..writeUint64(range.end);
      }
    }
    return writer.takeBytes();
  }

  static PlainChunk decode(List<int> bytes) {
    if (_hasMagic(bytes, _plainChunkMagic)) {
      return _decodeBinary(bytes);
    }
    throw const FormatException('unsupported legacy JSON chunk');
  }

  static PlainChunk _decodeBinary(List<int> bytes) {
    final reader = _BinaryReader(bytes);
    reader.expectUint32(_plainChunkMagic);
    final version = reader.readUint8();
    if (version != 4) {
      throw FormatException('unsupported chunk version $version');
    }
    final direction = _directionFromId(reader.readUint8());
    final sessionId = reader.readString();
    final sequenceNumber = reader.readUint64();
    final chunkEpoch = reader.readString();
    if (chunkEpoch.isEmpty) {
      throw const FormatException('v4 chunks require a chunk epoch');
    }
    final reliableSequenceNumber = reader.readUint64();
    final ackOnly = reader.readUint8() != 0;
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
      final sackRangeCount = reader.readUint32();
      final sackRanges = <AckRange>[];
      for (var j = 0; j < sackRangeCount; j++) {
        sackRanges.add(
          AckRange(start: reader.readUint64(), end: reader.readUint64()),
        );
      }
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
          sackRanges: sackRanges,
        ),
      );
    }
    reader.expectDone();
    return PlainChunk(
      version: version,
      sessionId: sessionId,
      direction: direction,
      sequenceNumber: sequenceNumber,
      chunkEpoch: chunkEpoch,
      reliableSequenceNumber: reliableSequenceNumber,
      ackOnly: ackOnly,
      frames: frames,
    );
  }
}

/// Authenticated metadata for an encrypted tunnel file.
class EncryptedChunkMetadata {
  const EncryptedChunkMetadata({
    required this.version,
    required this.sessionId,
    required this.direction,
    required this.sequenceNumber,
    required this.nonce,
    this.compressed = false,
    this.chunkEpoch,
  });

  final int version;
  final String sessionId;
  final Direction direction;
  final int sequenceNumber;
  final List<int> nonce;
  final bool compressed;
  final String? chunkEpoch;

  List<int> aad() {
    // Metadata is not secret, but it must be authenticated so chunks cannot be
    // moved across sessions, directions, or sequence numbers.
    if (version != 4) {
      throw FormatException('unsupported chunk version $version');
    }
    final chunkEpoch = this.chunkEpoch;
    if (chunkEpoch == null || chunkEpoch.isEmpty) {
      throw const FormatException('v4 chunks require a chunk epoch');
    }
    return utf8.encode(
      'btun|$version|$sessionId|${direction.name}|$sequenceNumber|'
      '${compressed ? 1 : 0}|$chunkEpoch',
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
    'chunk_epoch': chunkEpoch,
  };

  static EncryptedChunkMetadata fromJson(Map<String, Object?> json) {
    throw const FormatException('unsupported legacy JSON encrypted chunk');
  }
}

/// Complete encrypted file payload uploaded to Bale Saved Messages.
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
    if (metadata.version != 4) {
      throw FormatException('unsupported chunk version ${metadata.version}');
    }
    final chunkEpoch = metadata.chunkEpoch;
    if (chunkEpoch == null || chunkEpoch.isEmpty) {
      throw const FormatException('v4 chunks require a chunk epoch');
    }
    final writer = _BinaryWriter()
      ..writeUint32(_encryptedChunkMagic)
      ..writeUint8(metadata.version)
      ..writeUint8(_directionId(metadata.direction))
      ..writeUint8(metadata.compressed ? 1 : 0)
      ..writeString(metadata.sessionId)
      ..writeUint64(metadata.sequenceNumber)
      ..writeString(chunkEpoch);
    return (writer
          ..writeBytes(metadata.nonce)
          ..writeBytes(mac)
          ..writeBytes(cipherText))
        .takeBytes();
  }

  static EncryptedChunkFile decode(List<int> bytes) {
    if (_hasMagic(bytes, _encryptedChunkMagic)) {
      return _decodeBinary(bytes);
    }
    throw const FormatException('unsupported legacy JSON encrypted chunk');
  }

  static EncryptedChunkFile _decodeBinary(List<int> bytes) {
    final reader = _BinaryReader(bytes);
    reader.expectUint32(_encryptedChunkMagic);
    final version = reader.readUint8();
    if (version != 4) {
      throw FormatException('unsupported chunk version $version');
    }
    final direction = _directionFromId(reader.readUint8());
    final compressed = reader.readUint8() != 0;
    final sessionId = reader.readString();
    final sequenceNumber = reader.readUint64();
    final chunkEpoch = reader.readString();
    if (chunkEpoch.isEmpty) {
      throw const FormatException('v4 chunks require a chunk epoch');
    }
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
        chunkEpoch: chunkEpoch,
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
