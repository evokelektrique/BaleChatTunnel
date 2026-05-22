import 'dart:convert';
import 'dart:typed_data';

import 'package:bale_client/src/grpc_web.dart';
import 'package:test/test.dart';

void main() {
  test('round trips a data frame', () {
    final payload = Uint8List.fromList([1, 2, 3, 4]);
    final frame = grpcWebEncode(payload);
    expect(frame[0], 0);
    expect(grpcWebDecode(frame), payload);
  });

  test('throws on trailer error', () {
    final trailer = utf8.encode(
      'grpc-status: 3\r\ngrpc-message: bad%20code\r\n',
    );
    final frame = Uint8List(5 + trailer.length);
    frame[0] = 0x80;
    frame.buffer.asByteData().setUint32(1, trailer.length);
    frame.setRange(5, frame.length, trailer);

    expect(
      () => grpcWebDecode(frame),
      throwsA(
        isA<GrpcWebException>()
            .having((e) => e.status, 'status', 3)
            .having((e) => e.message, 'message', 'bad code'),
      ),
    );
  });
}
