import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'logger.dart';
import 'tunnel_client.dart';

class Socks5Server {
  Socks5Server({
    required this.host,
    required this.port,
    required this.client,
    required this.logger,
  });

  final String host;
  final int port;
  final BtunClient client;
  final Logger logger;
  ServerSocket? _server;
  final _connections = <Socket>{};

  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    _server = await ServerSocket.bind(host, port);
    _server!.listen((socket) {
      _connections.add(socket);
      unawaited(
        _handle(socket).whenComplete(() => _connections.remove(socket)),
      );
    });
  }

  Future<void> _handle(Socket socket) async {
    BtunStream? remote;
    _SocketReadBuffer? reader;
    try {
      reader = _SocketReadBuffer(socket);
      await _handshake(reader);
      final request = await _readConnect(reader);
      logger.info('SOCKS open requested ${request.host}:${request.port}');
      remote = await client.open(request.host, request.port);
      logger.info('SOCKS connected ${request.host}:${request.port}');
      socket.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      final remoteSub = remote.incoming.listen(
        (data) {
          try {
            socket.add(data);
          } on Object {
            socket.destroy();
          }
        },
        onDone: () => socket.destroy(),
        onError: (_) => socket.destroy(),
      );
      final localSub = reader.release().listen(
        (data) => unawaited(remote!.add(data).catchError((Object _) {})),
        onDone: () => unawaited(remote!.closeWrite().catchError((Object _) {})),
        onError: (_) => unawaited(
          remote!.reset('local socket error').catchError((Object _) {}),
        ),
      );
      await Future.any([remote.incoming.drain<void>(), socket.done]);
      await localSub.cancel();
      await remoteSub.cancel();
    } on Object catch (error) {
      if (!_isQuietSocketClose(error)) {
        logger.warn('SOCKS connection failed: $error');
      }
      try {
        socket.add([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      } catch (_) {}
    } finally {
      await remote?.close();
      await reader?.cancel();
      socket.destroy();
    }
  }

  Future<void> _handshake(_SocketReadBuffer socket) async {
    final head = await socket.readExactly(2);
    if (head[0] != 0x05) {
      throw const FormatException('only SOCKS5 is supported');
    }
    final methods = await socket.readExactly(head[1]);
    if (!methods.contains(0x00)) {
      socket.socket.add([0x05, 0xff]);
      throw const FormatException('SOCKS auth method unsupported');
    }
    socket.socket.add([0x05, 0x00]);
  }

  Future<_ConnectRequest> _readConnect(_SocketReadBuffer socket) async {
    final head = await socket.readExactly(4);
    if (head[0] != 0x05 || head[1] != 0x01) {
      throw const FormatException('only SOCKS5 CONNECT is supported');
    }
    final atyp = head[3];
    late final String host;
    switch (atyp) {
      case 0x01:
        final bytes = await socket.readExactly(4);
        host = InternetAddress.fromRawAddress(
          Uint8List.fromList(bytes),
        ).address;
      case 0x03:
        final len = (await socket.readExactly(1))[0];
        host = String.fromCharCodes(await socket.readExactly(len));
      case 0x04:
        final bytes = await socket.readExactly(16);
        host = InternetAddress.fromRawAddress(
          Uint8List.fromList(bytes),
        ).address;
      default:
        throw FormatException('unsupported address type $atyp');
    }
    final portBytes = await socket.readExactly(2);
    final port = (portBytes[0] << 8) | portBytes[1];
    return _ConnectRequest(host, port);
  }

  Future<void> close() async {
    for (final socket in _connections.toList()) {
      socket.destroy();
    }
    await _server?.close();
  }

  bool _isQuietSocketClose(Object error) {
    if (error is SocketException) {
      return error.osError?.errorCode == 32 ||
          error.message.contains('Broken pipe') ||
          error.message.contains('Connection reset');
    }
    return false;
  }
}

class _ConnectRequest {
  const _ConnectRequest(this.host, this.port);

  final String host;
  final int port;
}

class _SocketReadBuffer {
  _SocketReadBuffer(this.socket) {
    _sub = socket.listen(
      _onData,
      onError: _controller.addError,
      onDone: () {
        _done = true;
        _controller.close();
      },
      cancelOnError: true,
    );
  }

  final Socket socket;
  final _buffer = BytesBuilder(copy: false);
  final _controller = StreamController<List<int>>();
  late final StreamSubscription<List<int>> _sub;
  Completer<void>? _waiter;
  bool _released = false;
  bool _done = false;

  Future<List<int>> readExactly(int length) async {
    final out = BytesBuilder(copy: false);
    while (out.length < length) {
      final available = _buffer.takeBytes();
      if (available.isNotEmpty) {
        final need = length - out.length;
        if (available.length <= need) {
          out.add(available);
        } else {
          out.add(available.sublist(0, need));
          _buffer.add(available.sublist(need));
        }
        continue;
      }
      if (_done) throw const SocketException('socket closed');
      _waiter = Completer<void>();
      await _waiter!.future.timeout(const Duration(seconds: 10));
    }
    return out.takeBytes();
  }

  Stream<List<int>> release() {
    _released = true;
    final rest = _buffer.takeBytes();
    if (rest.isNotEmpty) _controller.add(rest);
    return _controller.stream;
  }

  Future<void> cancel() async {
    await _sub.cancel();
    if (!_controller.isClosed) await _controller.close();
  }

  void _onData(List<int> data) {
    if (_released) {
      _controller.add(data);
      return;
    }
    _buffer.add(data);
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }
}
