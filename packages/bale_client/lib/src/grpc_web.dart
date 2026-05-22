import 'dart:convert';
import 'dart:typed_data';

class GrpcWebException implements Exception {
  const GrpcWebException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'gRPC-web error $status: $message';
}

Uint8List grpcWebEncode(List<int> payload) {
  final out = Uint8List(5 + payload.length);
  out[0] = 0;
  out.buffer.asByteData().setUint32(1, payload.length, Endian.big);
  out.setRange(5, out.length, payload);
  return out;
}

Uint8List grpcWebDecode(List<int> bytes) {
  final data = Uint8List.fromList(bytes);
  var position = 0;
  Uint8List? result;
  var status = 0;
  var message = '';

  while (position + 5 <= data.length) {
    final flag = data[position];
    final length = data.buffer.asByteData().getUint32(position + 1, Endian.big);
    position += 5;
    final end = position + length;
    if (end > data.length) {
      throw const FormatException('Malformed gRPC-web frame');
    }

    final frame = Uint8List.sublistView(data, position, end);
    position = end;

    if ((flag & 0x80) == 0) {
      result = frame;
      continue;
    }

    final trailer = utf8.decode(frame, allowMalformed: true);
    final statusMatch = RegExp(r'grpc-status:\s*(\d+)').firstMatch(trailer);
    if (statusMatch != null) status = int.parse(statusMatch.group(1)!);

    final messageMatch = RegExp(
      r'grpc-message:\s*([^\r\n]+)',
    ).firstMatch(trailer);
    if (messageMatch != null) {
      message = Uri.decodeComponent(messageMatch.group(1)!.trim());
    }
  }

  if (status != 0) {
    throw GrpcWebException(
      status,
      message.isEmpty ? 'gRPC error $status' : message,
    );
  }
  return result ?? Uint8List(0);
}
