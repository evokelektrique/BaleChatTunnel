import 'dart:convert';
import 'dart:typed_data';

class ProtoWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  ProtoWriter varint(int value) {
    var v = value;
    while ((v & ~0x7f) != 0) {
      _builder.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
    _builder.addByte(v & 0x7f);
    return this;
  }

  ProtoWriter tag(int field, int wireType) => varint((field << 3) | wireType);

  ProtoWriter int32(int field, int value) {
    tag(field, 0);
    return varint(value);
  }

  ProtoWriter int64(int field, int value) {
    tag(field, 0);
    return varint(value);
  }

  ProtoWriter boolValue(int field, bool value) {
    tag(field, 0);
    return varint(value ? 1 : 0);
  }

  ProtoWriter string(int field, String value) =>
      bytes(field, utf8.encode(value));

  ProtoWriter bytes(int field, List<int> value) {
    tag(field, 2);
    varint(value.length);
    _builder.add(value);
    return this;
  }

  Uint8List build() => _builder.toBytes();
}

class ProtoReader {
  ProtoReader(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  int position = 0;

  bool get hasMore => position < _bytes.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (position < _bytes.length) {
      final byte = _bytes[position++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
      if (shift > 70) {
        throw const FormatException('Invalid protobuf varint');
      }
    }
    throw const FormatException('Unexpected end of protobuf varint');
  }

  (int field, int wireType) tag() {
    final value = varint();
    return (value >>> 3, value & 7);
  }

  Uint8List bytes() {
    final length = varint();
    final end = position + length;
    if (length < 0 || end > _bytes.length) {
      throw const FormatException('Invalid protobuf length-delimited field');
    }
    final result = Uint8List.sublistView(_bytes, position, end);
    position = end;
    return result;
  }

  String string() => utf8.decode(bytes());

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        position += 8;
      case 2:
        final length = varint();
        position += length;
      case 5:
        position += 4;
      default:
        throw FormatException('Unsupported protobuf wire type $wireType');
    }
    if (position > _bytes.length) {
      throw const FormatException('Skipped beyond protobuf message length');
    }
  }
}

String? decodeWrappedString(List<int> bytes) {
  final reader = ProtoReader(bytes);
  while (reader.hasMore) {
    final (field, wire) = reader.tag();
    if (field == 1 && wire == 2) return reader.string();
    reader.skip(wire);
  }
  return null;
}

int? decodeWrappedInt(List<int> bytes) {
  final reader = ProtoReader(bytes);
  while (reader.hasMore) {
    final (field, wire) = reader.tag();
    if (field == 1 && wire == 0) return reader.varint();
    reader.skip(wire);
  }
  return null;
}
