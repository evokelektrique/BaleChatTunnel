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
  final _bulkStreams = <int>{};
  final _streamPayloadBytes = <int, int>{};
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
    var hasTinyData = false;
    for (final frame in frames) {
      _queuedFrames.add(frame);
      _queuedBytes += _estimateFrameBytes(frame);
      if (_isUrgentControl(frame)) hasUrgentControl = true;
      if (_isInteractiveControl(frame)) hasInteractiveControl = true;
      if (_isBulkData(frame)) hasBulkData = true;
      if (_isTinyData(frame)) hasTinyData = true;
    }
    if (_queuedBytes >= _currentChunkTarget || hasTinyData) {
      await flush();
      return;
    }
    final delay = hasUrgentControl || hasInteractiveControl
        ? controlFlushDelay
        : hasBulkData
        ? bulkFlushDelay
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
    _logChunkSummary(sequence, frames);
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
    final total =
        (_streamPayloadBytes[frame.streamId] ?? 0) + frame.payload.length;
    _streamPayloadBytes[frame.streamId] = total;
    if (total >= chunkSize) _bulkStreams.add(frame.streamId);
    return _bulkStreams.contains(frame.streamId);
  }

  bool _isTinyData(TunnelFrame frame) {
    return frame.type == FrameType.data &&
        immediateDataThreshold >= 0 &&
        frame.payload.length <= immediateDataThreshold;
  }

  int get _currentChunkTarget {
    if (_queuedFrames.any(
      (frame) =>
          frame.type == FrameType.data && _bulkStreams.contains(frame.streamId),
    )) {
      return bulkChunkSize > chunkSize ? bulkChunkSize : chunkSize;
    }
    return chunkSize;
  }

  int _estimateFrameBytes(TunnelFrame frame) {
    return frame.payload.length + (frame.host?.length ?? 0) + 256;
  }

  void _logChunkSummary(int sequence, List<TunnelFrame> frames) {
    final counts = <FrameType, int>{};
    var payloadBytes = 0;
    for (final frame in frames) {
      counts[frame.type] = (counts[frame.type] ?? 0) + 1;
      payloadBytes += frame.payload.length;
    }
    final types = counts.entries
        .map((entry) => '${entry.key.name}:${entry.value}')
        .join(',');
    logger.info(
      'chunk seq=$sequence frames=${frames.length} types=$types '
      'payload=$payloadBytes',
    );
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
