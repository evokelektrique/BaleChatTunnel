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
  final _slotWaiters = <Completer<void>>[];
  late final StreamSubscription<TunnelFrame> _sub;

  Future<BtunStream> open(
    String host,
    int port, {
    Duration slotTimeout = const Duration(minutes: 2),
  }) async {
    await _waitForStreamSlot(slotTimeout);
    final streamId = _nextStreamId();
    final stream = BtunStream._(
      streamId: streamId,
      host: host,
      port: port,
      waitWritable: chunkTransport.waitUntilWritable,
      sendData: (bytes) => _sendData(streamId, bytes),
      closeRemote: () => _sendClose(streamId),
      resetRemote: (message) => _sendReset(streamId, message),
      onClosed: () => _removeStream(streamId),
    );
    _streams[streamId] = stream;
    try {
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
    } on Object {
      _removeStream(streamId);
      rethrow;
    }
    return stream;
  }

  Future<Uint8List> requestBytes(
    String host,
    int port,
    List<int> request, {
    bool closeAfterWrite = false,
    Duration timeout = const Duration(minutes: 5),
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
        _removeStream(frame.streamId);
      case FrameType.reset:
      case FrameType.error:
        stream!._error(frame.message ?? 'remote reset');
        _removeStream(frame.streamId);
      case FrameType.open:
      case FrameType.ack:
      case FrameType.hello:
      case FrameType.ready:
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

  Future<void> _waitForStreamSlot(Duration timeout) async {
    final limit = config.maxStreams <= 0 ? 1 : config.maxStreams;
    final deadline = DateTime.now().add(timeout);
    while (_streams.length >= limit) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'timed out waiting for a tunnel stream slot',
          timeout,
        );
      }
      final waiter = Completer<void>();
      _slotWaiters.add(waiter);
      try {
        await waiter.future.timeout(remaining);
      } on TimeoutException {
        _slotWaiters.remove(waiter);
        rethrow;
      }
    }
  }

  void _removeStream(int streamId) {
    if (_streams.remove(streamId) == null) return;
    while (_slotWaiters.isNotEmpty) {
      final waiter = _slotWaiters.removeAt(0);
      if (!waiter.isCompleted) {
        waiter.complete();
        break;
      }
    }
  }

  Future<void> close() async {
    for (final stream in _streams.values.toList()) {
      await stream.close();
    }
    for (final waiter in _slotWaiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _slotWaiters.clear();
    await _sub.cancel();
  }
}

class BtunStream {
  BtunStream._({
    required this.streamId,
    required this.host,
    required this.port,
    required Future<void> Function() waitWritable,
    required Future<void> Function(List<int>) sendData,
    required Future<void> Function() closeRemote,
    required Future<void> Function(String) resetRemote,
    required void Function() onClosed,
  }) : _waitWritable = waitWritable,
       _sendData = sendData,
       _closeRemote = closeRemote,
       _resetRemote = resetRemote,
       _onClosed = onClosed;

  final int streamId;
  final String host;
  final int port;
  final Future<void> Function() _waitWritable;
  final Future<void> Function(List<int>) _sendData;
  final Future<void> Function() _closeRemote;
  final Future<void> Function(String) _resetRemote;
  final void Function() _onClosed;
  final StreamController<List<int>> _incoming =
      StreamController<List<int>>.broadcast();
  var _closed = false;
  var _writeClosed = false;

  Stream<List<int>> get incoming => _incoming.stream;

  Future<void> add(List<int> bytes) async {
    if (_closed || bytes.isEmpty) return;
    await _waitUntilWritable();
    await _sendData(bytes);
  }

  Future<void> closeWrite() async {
    if (_writeClosed) return;
    _writeClosed = true;
    await _closeRemote();
  }

  Future<void> reset(String message) async {
    if (_closed) return;
    _closed = true;
    _onClosed();
    await _resetRemote(message);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await closeWrite();
    await _incoming.close();
    _onClosed();
  }

  void _add(List<int> bytes) {
    if (!_incoming.isClosed) _incoming.add(Uint8List.fromList(bytes));
  }

  void _closeIncoming() {
    _closed = true;
    if (!_incoming.isClosed) _incoming.close();
    _onClosed();
  }

  void _error(String message) {
    _closed = true;
    if (!_incoming.isClosed) {
      _incoming.addError(Exception(message));
      _incoming.close();
    }
    _onClosed();
  }

  Future<void> _waitUntilWritable() => _waitWritable();
}
