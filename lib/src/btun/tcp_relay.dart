import 'dart:async';
import 'dart:io';

import 'chunk_transport.dart';
import 'logger.dart';
import 'protocol.dart';

class TcpRelay {
  TcpRelay({required this.chunkTransport, required this.logger});

  final ChunkTransport chunkTransport;
  final Logger logger;
  final _streams = <int, _RelayStream>{};
  final _closedStreams = <int>{};
  StreamSubscription<TunnelFrame>? _sub;

  Future<void> start() async {
    _sub = chunkTransport.frames.listen((frame) {
      unawaited(_handleFrame(frame));
    });
  }

  Future<void> _handleFrame(TunnelFrame frame) async {
    switch (frame.type) {
      case FrameType.open:
        await _open(frame);
      case FrameType.data:
        _data(frame.streamId, frame.payload);
      case FrameType.close:
        await _closeInput(frame.streamId);
      case FrameType.reset:
        _resetLocal(frame.streamId);
      case FrameType.hello:
      case FrameType.ready:
      case FrameType.ack:
      case FrameType.ping:
      case FrameType.pong:
      case FrameType.error:
        break;
    }
  }

  Future<void> _open(TunnelFrame frame) async {
    final host = frame.host;
    final port = frame.port;
    if (host == null || port == null) {
      await _reset(frame.streamId, 'OPEN missing host or port');
      return;
    }
    if (_closedStreams.contains(frame.streamId)) {
      logger.warn(
        'relay ignored duplicate OPEN for closed stream=${frame.streamId}',
      );
      return;
    }
    try {
      final stream = _streams.putIfAbsent(frame.streamId, _RelayStream.new);
      stream.state = _RelayStreamState.opening;
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 30),
      );
      if (stream.reset) {
        socket.destroy();
        return;
      }
      stream.socket = socket;
      stream.state = _RelayStreamState.open;
      for (final pending in stream.pendingData) {
        _addToSocket(frame.streamId, stream, pending);
      }
      stream.pendingData.clear();
      if (stream.closeAfterOpen) {
        await socket.close();
        await _sendClose(frame.streamId);
        return;
      }
      socket.listen(
        (data) => unawaited(_sendData(frame.streamId, data)),
        onDone: () => unawaited(_sendClose(frame.streamId)),
        onError: (Object error) =>
            unawaited(_reset(frame.streamId, error.toString())),
        cancelOnError: true,
      );
    } on Object catch (error) {
      logger.warn('relay open failed for $host:$port: $error');
      _streams.remove(frame.streamId)?.destroy();
      await _reset(frame.streamId, error.toString());
    }
  }

  void _data(int streamId, List<int> data) {
    if (_closedStreams.contains(streamId)) {
      logger.info('relay ignored DATA for closed stream=$streamId');
      return;
    }
    final stream = _streams.putIfAbsent(streamId, _RelayStream.new);
    if (stream.state == _RelayStreamState.closing ||
        stream.state == _RelayStreamState.closed ||
        stream.reset) {
      logger.info('relay ignored DATA for closed stream=$streamId');
      return;
    }
    final socket = stream.socket;
    if (socket == null) {
      stream.pendingData.add(List<int>.from(data));
      return;
    }
    _addToSocket(streamId, stream, data);
  }

  Future<void> _closeInput(int streamId) async {
    final stream = _streams[streamId];
    if (stream == null) return;
    stream.state = _RelayStreamState.closing;
    final socket = stream.socket;
    if (socket == null) {
      stream.closeAfterOpen = true;
      return;
    }
    try {
      await socket.close();
    } on Object catch (error) {
      logger.warn('relay close failed stream=$streamId: $error');
    }
  }

  void _resetLocal(int streamId) {
    _closedStreams.add(streamId);
    _streams.remove(streamId)?.destroy();
  }

  void _addToSocket(int streamId, _RelayStream stream, List<int> data) {
    final socket = stream.socket;
    if (socket == null) return;
    try {
      socket.add(data);
    } on Object catch (error) {
      logger.info('relay ignored DATA for closed stream=$streamId: $error');
      _closedStreams.add(streamId);
      _streams.remove(streamId)?.destroy();
    }
  }

  Future<void> _sendData(int streamId, List<int> data) {
    return chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: chunkTransport.sessionId,
        direction: Direction.r2c,
        streamId: streamId,
        sequenceNumber: chunkTransport.allocateSequence(),
        payload: data,
      ),
    );
  }

  Future<void> _sendClose(int streamId) {
    _closedStreams.add(streamId);
    _streams.remove(streamId);
    return chunkTransport.sendFrame(
      TunnelFrame.close(
        sessionId: chunkTransport.sessionId,
        direction: Direction.r2c,
        streamId: streamId,
        sequenceNumber: chunkTransport.allocateSequence(),
      ),
    );
  }

  Future<void> _reset(int streamId, String message) {
    _closedStreams.add(streamId);
    _streams.remove(streamId)?.destroy();
    return chunkTransport.sendFrame(
      TunnelFrame.reset(
        sessionId: chunkTransport.sessionId,
        direction: Direction.r2c,
        streamId: streamId,
        sequenceNumber: chunkTransport.allocateSequence(),
        message: message,
      ),
    );
  }

  Future<void> close() async {
    await _sub?.cancel();
    for (final stream in _streams.values.toList()) {
      stream.destroy();
    }
    _streams.clear();
    _closedStreams.clear();
  }
}

class _RelayStream {
  Socket? socket;
  _RelayStreamState state = _RelayStreamState.pending;
  bool closeAfterOpen = false;
  bool reset = false;
  final pendingData = <List<int>>[];

  void destroy() {
    reset = true;
    state = _RelayStreamState.closed;
    pendingData.clear();
    socket?.destroy();
  }
}

enum _RelayStreamState { pending, opening, open, closing, closed }
