import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'chunk_transport.dart';
import 'config.dart';
import 'protocol.dart';

class BtunClient {
  BtunClient({required this.config, required this.chunkTransport}) {
    _sub = chunkTransport.frames.listen(_handleFrame);
  }

  final BtunConfig config;
  final ChunkTransport chunkTransport;
  final _random = Random.secure();
  final _streams = <int, BtunStream>{};
  late final StreamSubscription<TunnelFrame> _sub;

  Future<BtunStream> open(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final streamId = _nextStreamId();
    final stream = BtunStream._(
      streamId: streamId,
      host: host,
      port: port,
      sendData: (bytes) => _sendData(streamId, bytes),
      closeRemote: () => _sendClose(streamId),
      resetRemote: (message) => _sendReset(streamId, message),
    );
    _streams[streamId] = stream;
    await chunkTransport.sendFrame(
      TunnelFrame.open(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: streamId,
        sequenceNumber: chunkTransport.allocateSequence(),
        host: host,
        port: port,
      ),
    );
    try {
      await stream._ready.future.timeout(timeout);
      return stream;
    } on Object {
      _streams.remove(streamId);
      await stream.close(localOnly: true);
      rethrow;
    }
  }

  Future<Uint8List> requestBytes(
    String host,
    int port,
    List<int> request, {
    bool closeAfterWrite = false,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final stream = await open(host, port);
    final out = BytesBuilder(copy: false);
    final done = Completer<Uint8List>();
    late final StreamSubscription<List<int>> sub;
    sub = stream.incoming.listen(
      out.add,
      onDone: () {
        if (!done.isCompleted) done.complete(out.takeBytes());
      },
      onError: done.completeError,
    );
    await stream.add(request);
    if (closeAfterWrite) await stream.closeWrite();
    try {
      return await done.future.timeout(timeout);
    } finally {
      await sub.cancel();
      await stream.close();
    }
  }

  void _handleFrame(TunnelFrame frame) {
    final stream = _streams[frame.streamId];
    if (stream == null && frame.type != FrameType.ack) return;
    switch (frame.type) {
      case FrameType.data:
        stream!._add(frame.payload);
      case FrameType.close:
        stream!._closeIncoming();
        _streams.remove(frame.streamId);
      case FrameType.reset:
      case FrameType.error:
        stream!._error(frame.message ?? 'remote reset');
        _streams.remove(frame.streamId);
      case FrameType.ready:
        stream!._markReady();
      case FrameType.open:
      case FrameType.ack:
      case FrameType.hello:
      case FrameType.ping:
      case FrameType.pong:
        break;
    }
  }

  Future<void> _sendData(int streamId, List<int> bytes) {
    return chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: streamId,
        sequenceNumber: chunkTransport.allocateSequence(),
        payload: bytes,
      ),
    );
  }

  Future<void> _sendClose(int streamId) {
    return chunkTransport.sendFrame(
      TunnelFrame.close(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: streamId,
        sequenceNumber: chunkTransport.allocateSequence(),
      ),
    );
  }

  Future<void> _sendReset(int streamId, String message) {
    return chunkTransport.sendFrame(
      TunnelFrame.reset(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: streamId,
        sequenceNumber: chunkTransport.allocateSequence(),
        message: message,
      ),
    );
  }

  int _nextStreamId() {
    var id = _random.nextInt(0x3fffffff) + 1;
    while (_streams.containsKey(id)) {
      id = _random.nextInt(0x3fffffff) + 1;
    }
    return id;
  }

  Future<void> close() async {
    for (final stream in _streams.values.toList()) {
      await stream.close();
    }
    await _sub.cancel();
  }
}

class BtunStream {
  BtunStream._({
    required this.streamId,
    required this.host,
    required this.port,
    required Future<void> Function(List<int>) sendData,
    required Future<void> Function() closeRemote,
    required Future<void> Function(String) resetRemote,
  }) : _sendData = sendData,
       _closeRemote = closeRemote,
       _resetRemote = resetRemote;

  final int streamId;
  final String host;
  final int port;
  final Future<void> Function(List<int>) _sendData;
  final Future<void> Function() _closeRemote;
  final Future<void> Function(String) _resetRemote;
  final StreamController<List<int>> _incoming =
      StreamController<List<int>>.broadcast();
  final Completer<void> _ready = Completer<void>();
  var _closed = false;
  var _writeClosed = false;

  Stream<List<int>> get incoming => _incoming.stream;

  Future<void> add(List<int> bytes) async {
    if (_closed || bytes.isEmpty) return;
    await _sendData(bytes);
  }

  Future<void> closeWrite() async {
    if (_writeClosed) return;
    _writeClosed = true;
    await _closeRemote();
  }

  Future<void> reset(String message) => _resetRemote(message);

  Future<void> close({bool localOnly = false}) async {
    if (_closed) return;
    _closed = true;
    if (!localOnly) await closeWrite();
    await _incoming.close();
  }

  void _markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void _add(List<int> bytes) {
    if (!_incoming.isClosed) _incoming.add(Uint8List.fromList(bytes));
  }

  void _closeIncoming() {
    _closed = true;
    if (!_incoming.isClosed) _incoming.close();
  }

  void _error(String message) {
    _closed = true;
    final wasReady = _ready.isCompleted;
    if (!_ready.isCompleted) _ready.completeError(Exception(message));
    if (wasReady && !_incoming.isClosed) {
      _incoming.addError(Exception(message));
      _incoming.close();
    }
  }
}
