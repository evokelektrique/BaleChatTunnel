import 'dart:typed_data';

import 'package:bale_client/src/protobuf.dart';
import 'package:test/test.dart';

void main() {
  test('encodes and decodes primitive fields', () {
    final bytes = ProtoWriter()
        .int32(1, 42)
        .int64(2, 151668)
        .string(3, 'hello')
        .bytes(4, [1, 2, 3])
        .boolValue(5, true)
        .build();

    final reader = ProtoReader(bytes);

    expect(reader.tag(), (1, 0));
    expect(reader.varint(), 42);
    expect(reader.tag(), (2, 0));
    expect(reader.varint(), 151668);
    expect(reader.tag(), (3, 2));
    expect(reader.string(), 'hello');
    expect(reader.tag(), (4, 2));
    expect(reader.bytes(), Uint8List.fromList([1, 2, 3]));
    expect(reader.tag(), (5, 0));
    expect(reader.varint(), 1);
    expect(reader.hasMore, isFalse);
  });

  test('skips unknown fields', () {
    final nested = ProtoWriter().string(1, 'ignored').build();
    final bytes = ProtoWriter().bytes(10, nested).string(1, 'kept').build();

    final reader = ProtoReader(bytes);
    final (unknown, wire) = reader.tag();
    expect(unknown, 10);
    reader.skip(wire);
    expect(reader.tag(), (1, 2));
    expect(reader.string(), 'kept');
  });

  test('decodes wrapped values', () {
    final stringValue = ProtoWriter().string(1, 'token').build();
    final intValue = ProtoWriter().int32(1, 65536).build();

    expect(decodeWrappedString(stringValue), 'token');
    expect(decodeWrappedInt(intValue), 65536);
  });
}
