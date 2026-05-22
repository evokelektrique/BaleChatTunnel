import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

abstract interface class BaleWebSocket {
  Stream<dynamic> get stream;
  void add(List<int> data);
  Future<void> close([int? closeCode, String? closeReason]);
  int? get closeCode;
}

typedef BaleWebSocketConnector =
    Future<BaleWebSocket> Function(Uri uri, Map<String, String> headers);

Future<BaleWebSocket> defaultBaleWebSocketConnector(
  Uri uri,
  Map<String, String> headers,
) async {
  final channel = IOWebSocketChannel.connect(uri, headers: headers);
  await channel.ready;
  return ChannelBaleWebSocket(channel);
}

class ChannelBaleWebSocket implements BaleWebSocket {
  ChannelBaleWebSocket(this._channel);

  final WebSocketChannel _channel;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void add(List<int> data) {
    _channel.sink.add(Uint8List.fromList(data));
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await _channel.sink.close(closeCode, closeReason);
  }
}
