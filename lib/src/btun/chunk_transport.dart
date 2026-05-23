import 'dart:async';

import 'crypto.dart';
import 'logger.dart';
import 'protocol.dart';
import 'state_db.dart';
import 'tunnel_transport.dart';

class ChunkTransport {
  ChunkTransport({
    required this.transport,
    required this.crypto,
    required this.stateDb,
    required this.sessionId,
    required this.sendDirection,
    required this.receiveDirection,
    required this.chunkSize,
    required this.retryTimeout,
    required this.maxInFlight,
    required this.logger,
    this.maxRetryChunks = 64,
    this.maxRetryBytes = 64 * 1024 * 1024,
    this.flushDelay = const Duration(milliseconds: 1000),
    this.bulkFlushDelay = const Duration(milliseconds: 250),
    this.bulkChunkSize = 524288,
    this.interactiveChunkSize = 4096,
    this.interactiveFlushDelay = const Duration(milliseconds: 20),
    this.interactiveFrameLimit = 8,
    this.interactiveWindow = const Duration(seconds: 3),
    this.streamIdleTimeout = const Duration(seconds: 2),
    @Deprecated('Adaptive chunking replaces immediate tiny DATA flushing.')
    this.immediateDataThreshold = 2048,
    this.controlFlushDelay = const Duration(milliseconds: 100),
    this.ackDelay = const Duration(milliseconds: 10000),
    this.retryTick = const Duration(seconds: 10),
  });

  final TunnelTransport transport;
  final BtunCrypto crypto;
  final StateDb stateDb;
  final String sessionId;
  final Direction sendDirection;
  final Direction receiveDirection;
  final int chunkSize;
  final Duration retryTimeout;
  final int maxInFlight;
  final Logger logger;
  final int maxRetryChunks;
  final int maxRetryBytes;
  final Duration flushDelay;
  final Duration bulkFlushDelay;
  final int bulkChunkSize;
  final int interactiveChunkSize;
  final Duration interactiveFlushDelay;
  final int interactiveFrameLimit;
  final Duration interactiveWindow;
  final Duration streamIdleTimeout;
  @Deprecated('Adaptive chunking replaces immediate tiny DATA flushing.')
  final int immediateDataThreshold;
  final Duration controlFlushDelay;
  final Duration ackDelay;
  final Duration retryTick;

  final StreamController<TunnelFrame> _frames =
      StreamController<TunnelFrame>.broadcast();
  StreamSubscription<IncomingTunnelFile>? _incomingSub;
  Timer? _retryTimer;
  Timer? _flushTimer;
  Timer? _ackTimer;
  Future<void> _flushTail = Future.value();
  final _queuedFrames = <TunnelFrame>[];
  final _streamStates = <int, _StreamChunkState>{};
  final _retryCache = <int, _RetryChunk>{};
  var _retryCacheBytes = 0;
  var _queuedBytes = 0;
  int? _pendingAck;
  var _nextSequence = DateTime.now().millisecondsSinceEpoch;
  var _closed = false;

  Stream<TunnelFrame> get frames => _frames.stream;

  Future<void> start() async {
    await transport.start();
    _incomingSub = transport.incomingFiles().listen((file) {
      unawaited(_handleIncoming(file));
    });
    _retryTimer = Timer.periodic(retryTick, (_) {
      unawaited(_retryDue());
    });
  }

  Future<void> sendFrames(List<TunnelFrame> frames) async {
    if (_closed) return;
    var hasUrgentControl = false;
    var hasInteractiveControl = false;
    var hasBulkData = false;
    var hasInteractiveData = false;
    for (final frame in frames) {
      _queuedFrames.add(frame);
      _queuedBytes += _estimateFrameBytes(frame);
      if (_isUrgentControl(frame)) hasUrgentControl = true;
      if (_isInteractiveControl(frame)) hasInteractiveControl = true;
      if (_isBulkData(frame)) hasBulkData = true;
      if (_isInteractiveData(frame)) hasInteractiveData = true;
    }
    if (_queuedBytes >= _currentChunkTarget) {
      await flush();
      return;
    }
    final delay = hasUrgentControl || hasInteractiveControl
        ? controlFlushDelay
        : hasBulkData
        ? bulkFlushDelay
        : hasInteractiveData
        ? _shorterDelay(flushDelay, interactiveFlushDelay)
        : flushDelay;
    _scheduleFlush(delay);
  }

  Future<void> flush() {
    _flushTail = _flushTail.then((_) => _flushNow());
    return _flushTail;
  }

  Future<void> _flushNow() async {
    if (_closed) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    final frames = <TunnelFrame>[..._queuedFrames];
    _queuedFrames.clear();
    _queuedBytes = 0;
    final ackNumber = _pendingAck;
    if (ackNumber != null) {
      frames.add(
        TunnelFrame.ack(
          sessionId: sessionId,
          direction: sendDirection,
          ackNumber: ackNumber,
        ),
      );
      _pendingAck = null;
      _ackTimer?.cancel();
      _ackTimer = null;
    }
    if (frames.isEmpty) return;
    final sequence = _nextSequence++;
    _logChunkSummary(sequence, frames, _targetForFrames(frames));
    final chunk = PlainChunk(
      version: 2,
      sessionId: sessionId,
      direction: sendDirection,
      sequenceNumber: sequence,
      frames: frames,
    );
    final encrypted = await crypto.encrypt(chunk);
    final bytes = encrypted.encode();
    final fileName = btunFileName(sessionId, sendDirection, sequence);
    final ackOnly = frames.every((frame) => frame.type == FrameType.ack);
    if (!ackOnly) _cacheRetry(sequence, fileName, bytes);
    try {
      await _sendFile(sequence, fileName, bytes, trackAck: !ackOnly);
    } on Object catch (error) {
      logger.warn('initial send failed for chunk $sequence: $error');
    }
  }

  Future<void> sendFrame(TunnelFrame frame) => sendFrames([frame]);

  int allocateSequence() => _nextSequence++;

  Future<void> _sendFile(
    int sequence,
    String fileName,
    List<int> bytes, {
    required bool trackAck,
  }) async {
    await transport.sendFile(
      OutgoingTunnelFile(
        fileName: fileName,
        bytes: bytes,
        sequenceNumber: sequence,
        direction: sendDirection,
      ),
    );
    if (trackAck) {
      _retryCache[sequence]?.markSent();
    }
  }

  Future<void> _handleIncoming(IncomingTunnelFile incoming) async {
    try {
      final encrypted = EncryptedChunkFile.decode(incoming.bytes);
      final meta = encrypted.metadata;
      if (meta.sessionId != sessionId || meta.direction != receiveDirection) {
        return;
      }
      final chunk = await crypto.decrypt(encrypted);
      if (chunk.sessionId != sessionId || chunk.direction != receiveDirection) {
        return;
      }
      final duplicate = stateDb.hasReceivedChunk(chunk.sequenceNumber);
      if (!duplicate) {
        stateDb.markReceivedChunk(chunk.sequenceNumber);
      }
      var shouldAck = false;
      for (final frame in chunk.frames) {
        if (frame.type == FrameType.ack) {
          _markRetryAcked(frame.ackNumber);
        } else {
          shouldAck = true;
          if (!duplicate) _frames.add(frame);
        }
      }
      if (shouldAck) _scheduleAck(chunk.sequenceNumber);
    } on Object catch (error) {
      logger.warn(
        'ignored corrupted or invalid tunnel file ${incoming.fileName}: $error',
      );
    }
  }

  void _scheduleAck(int sequenceNumber) {
    final pending = _pendingAck;
    if (pending == null || sequenceNumber > pending) {
      _pendingAck = sequenceNumber;
    }
    if (_queuedFrames.isNotEmpty) {
      _scheduleFlush(flushDelay);
      return;
    }
    if (ackDelay == Duration.zero) {
      unawaited(flush());
      return;
    }
    _ackTimer ??= Timer(ackDelay, () {
      _ackTimer = null;
      unawaited(flush());
    });
  }

  Future<void> _retryDue() async {
    if (_closed || transport.isBackingOff) return;
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - retryTimeout.inMilliseconds;
    final retryable =
        _retryCache.values
            .where(
              (record) =>
                  record.lastSentAt == null || record.lastSentAt! < cutoff,
            )
            .toList()
          ..sort((a, b) => a.sequenceNumber.compareTo(b.sequenceNumber));
    for (final record in retryable.take(maxInFlight)) {
      try {
        record.retryCount += 1;
        await transport.sendFile(
          OutgoingTunnelFile(
            fileName: record.fileName,
            bytes: record.bytes,
            sequenceNumber: record.sequenceNumber,
            direction: sendDirection,
          ),
        );
        record.markSent();
      } on Object catch (error) {
        logger.warn('retry failed for chunk ${record.sequenceNumber}: $error');
      }
    }
  }

  Future<void> close() async {
    await flush();
    _closed = true;
    _retryTimer?.cancel();
    _flushTimer?.cancel();
    _ackTimer?.cancel();
    await _incomingSub?.cancel();
    await _frames.close();
  }

  void _cacheRetry(int sequence, String fileName, List<int> bytes) {
    final previous = _retryCache.remove(sequence);
    if (previous != null) _retryCacheBytes -= previous.bytes.length;
    _retryCache[sequence] = _RetryChunk(
      sequenceNumber: sequence,
      fileName: fileName,
      bytes: List<int>.unmodifiable(bytes),
    );
    _retryCacheBytes += bytes.length;
    _trimRetryCache();
  }

  void _markRetryAcked(int ackNumber) {
    for (final sequence in _retryCache.keys.toList()) {
      if (sequence <= ackNumber) {
        final removed = _retryCache.remove(sequence);
        if (removed != null) _retryCacheBytes -= removed.bytes.length;
      }
    }
  }

  void _trimRetryCache() {
    final chunkLimit = maxRetryChunks <= 0 ? 1 : maxRetryChunks;
    final byteLimit = maxRetryBytes <= 0 ? chunkSize : maxRetryBytes;
    while (_retryCache.length > chunkLimit || _retryCacheBytes > byteLimit) {
      final oldest = _retryCache.keys.reduce((a, b) => a < b ? a : b);
      final removed = _retryCache.remove(oldest);
      if (removed == null) break;
      _retryCacheBytes -= removed.bytes.length;
      logger.warn(
        'evicted unacked chunk $oldest from memory retry cache '
        '(chunks=${_retryCache.length} bytes=$_retryCacheBytes)',
      );
    }
  }

  void _scheduleFlush(Duration delay) {
    if (_closed) return;
    if (delay == Duration.zero) {
      unawaited(
        flush().catchError((Object error) {
          logger.warn('flush failed: $error');
        }),
      );
      return;
    }
    final current = _flushTimer;
    if (current != null && current.isActive) return;
    _flushTimer = Timer(delay, () {
      _flushTimer = null;
      unawaited(
        flush().catchError((Object error) {
          logger.warn('flush failed: $error');
        }),
      );
    });
  }

  bool _isUrgentControl(TunnelFrame frame) {
    return frame.type == FrameType.reset || frame.type == FrameType.error;
  }

  bool _isInteractiveControl(TunnelFrame frame) {
    return frame.type == FrameType.open || frame.type == FrameType.close;
  }

  bool _isBulkData(TunnelFrame frame) {
    if (frame.type != FrameType.data) return false;
    final state = _stateFor(frame);
    return state.mode == _ChunkMode.bulk;
  }

  bool _isInteractiveData(TunnelFrame frame) {
    if (frame.type != FrameType.data) return false;
    final state = _streamStates[frame.streamId];
    return state == null || state.mode == _ChunkMode.interactive;
  }

  int get _currentChunkTarget {
    return _targetForFrames(_queuedFrames);
  }

  int _targetForFrames(List<TunnelFrame> frames) {
    var hasData = false;
    var hasBulk = false;
    var hasInteractive = false;
    for (final frame in frames) {
      if (frame.type != FrameType.data) continue;
      hasData = true;
      final mode = _modeFor(frame.streamId);
      if (mode == _ChunkMode.bulk) hasBulk = true;
      if (mode == _ChunkMode.interactive) hasInteractive = true;
    }
    if (!hasData) return _clampTarget(chunkSize);
    if (hasBulk) return _targetForMode(_ChunkMode.bulk);
    if (hasInteractive) return _targetForMode(_ChunkMode.interactive);
    return _targetForMode(_ChunkMode.steady);
  }

  _StreamChunkState _stateFor(TunnelFrame frame) {
    final now = DateTime.now();
    final state = _streamStates.putIfAbsent(
      frame.streamId,
      () => _StreamChunkState(now),
    );
    state.update(frame.payload.length, now, this);
    return state;
  }

  _ChunkMode _modeFor(int streamId) {
    return _streamStates[streamId]?.mode ?? _ChunkMode.steady;
  }

  int _targetForMode(_ChunkMode mode) {
    return switch (mode) {
      _ChunkMode.interactive => _minPositive(
        _clampTarget(interactiveChunkSize),
        _clampTarget(chunkSize),
      ),
      _ChunkMode.steady => _clampTarget(chunkSize),
      _ChunkMode.bulk => _clampTarget(
        bulkChunkSize > chunkSize ? bulkChunkSize : chunkSize,
      ),
    };
  }

  int _clampTarget(int value) {
    if (value <= 0) return 1;
    return value;
  }

  int _minPositive(int a, int b) {
    if (a <= 0) return b;
    if (b <= 0) return a;
    return a < b ? a : b;
  }

  Duration _shorterDelay(Duration a, Duration b) {
    if (a == Duration.zero || b == Duration.zero) return Duration.zero;
    return a < b ? a : b;
  }

  int _estimateFrameBytes(TunnelFrame frame) {
    return frame.payload.length + (frame.host?.length ?? 0) + 256;
  }

  void _logChunkSummary(int sequence, List<TunnelFrame> frames, int target) {
    final counts = <FrameType, int>{};
    var payloadBytes = 0;
    _ChunkMode? mode;
    for (final frame in frames) {
      counts[frame.type] = (counts[frame.type] ?? 0) + 1;
      payloadBytes += frame.payload.length;
      if (frame.type == FrameType.data) {
        final frameMode = _modeFor(frame.streamId);
        if (mode == null || frameMode.index > mode.index) mode = frameMode;
      }
    }
    final types = counts.entries
        .map((entry) => '${entry.key.name}:${entry.value}')
        .join(',');
    logger.info(
      'chunk seq=$sequence frames=${frames.length} types=$types '
      'payload=$payloadBytes mode=${(mode ?? _ChunkMode.steady).name} '
      'target=$target',
    );
  }
}

enum _ChunkMode { interactive, steady, bulk }

class _StreamChunkState {
  _StreamChunkState(DateTime now) : firstDataAt = now, lastDataAt = now;

  DateTime firstDataAt;
  DateTime lastDataAt;
  var frameCount = 0;
  var totalBytes = 0;
  _ChunkMode mode = _ChunkMode.interactive;

  void update(int bytes, DateTime now, ChunkTransport transport) {
    if (now.difference(lastDataAt) >= transport.streamIdleTimeout) {
      firstDataAt = now;
      frameCount = 0;
      totalBytes = 0;
      mode = _ChunkMode.interactive;
    }
    frameCount += 1;
    totalBytes += bytes;
    lastDataAt = now;
    if (totalBytes >= transport.chunkSize) {
      mode = _ChunkMode.bulk;
      return;
    }
    final interactiveFrames = transport.interactiveFrameLimit <= 0
        ? false
        : frameCount <= transport.interactiveFrameLimit;
    final interactiveTime =
        transport.interactiveWindow > Duration.zero &&
        now.difference(firstDataAt) <= transport.interactiveWindow;
    mode = interactiveFrames || interactiveTime
        ? _ChunkMode.interactive
        : _ChunkMode.steady;
  }
}

class _RetryChunk {
  _RetryChunk({
    required this.sequenceNumber,
    required this.fileName,
    required this.bytes,
  });

  final int sequenceNumber;
  final String fileName;
  final List<int> bytes;
  int retryCount = 0;
  int? lastSentAt;

  void markSent() {
    lastSentAt = DateTime.now().millisecondsSinceEpoch;
  }
}
