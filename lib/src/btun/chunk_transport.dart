import 'dart:async';
import 'dart:math';

import 'crypto.dart';
import 'logger.dart';
import 'protocol.dart';
import 'state_db.dart';
import 'tunnel_transport.dart';

/// Batches tunnel frames into encrypted files and handles ACK-based retries.
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
    this.maxReorderChunks = 128,
    this.maxReorderBytes = 256 * 1024 * 1024,
    this.receiveBaselineDelay = const Duration(seconds: 2),
    this.receiveGapTimeout,
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
  final int maxReorderChunks;
  final int maxReorderBytes;
  final Duration receiveBaselineDelay;
  final Duration? receiveGapTimeout;

  final StreamController<TunnelFrame> _frames =
      StreamController<TunnelFrame>.broadcast();
  StreamSubscription<IncomingTunnelFile>? _incomingSub;
  Timer? _retryTimer;
  Timer? _flushTimer;
  Timer? _ackTimer;
  Timer? _receiveBaselineTimer;
  Timer? _receiveGapTimer;
  Future<void> _flushTail = Future.value();
  final _queuedFrames = <TunnelFrame>[];
  final _streamStates = <int, _StreamChunkState>{};
  final _retryCache = <int, _RetryChunk>{};
  var _retryCacheBytes = 0;
  var _queuedBytes = 0;
  final _reorderBuffer = <int, _BufferedChunk>{};
  final _deliveredReceivedSequences = <int>{};
  var _reorderBufferBytes = 0;
  final String chunkEpoch = _newChunkEpoch();
  var _nextUploadSequence = 1;
  var _nextReliableSequence = 1;
  var _nextFrameSequence = 1;
  int? _nextReceiveSequence;
  String? _receiveChunkEpoch;
  var _closed = false;
  String? _closedReason;
  var _retryInProgress = false;
  DateTime? _retryNotBefore;
  DateTime? _receiveGapSince;
  _AckSnapshot? _lastSentAckSnapshot;
  DateTime? _lastSentAckAt;
  var _pendingAckDirty = false;
  var _ackElicitingSinceLastAck = 0;

  Stream<TunnelFrame> get frames => _frames.stream;

  bool get isCongested =>
      transport.isBackingOff ||
      _retryCache.length >= maxRetryChunks ||
      _retryCacheBytes >= maxRetryBytes ||
      _queuedBytes >= chunkSize * 2;

  Future<void> waitUntilWritable() async {
    // Backpressure protects memory and avoids producing files faster than Bale
    // can accept them during rate limits or retry pressure.
    while (!_closed && isCongested) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _throwIfClosed();
  }

  Future<void> start() async {
    _incomingSub = transport.incomingFiles().listen((file) {
      unawaited(_handleIncoming(file));
    });
    await transport.start();
    _retryTimer = Timer.periodic(retryTick, (_) {
      unawaited(_retryDue());
    });
  }

  Future<void> sendFrames(List<TunnelFrame> frames) async {
    _throwIfClosed();
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
    // Control frames and early stream data are flushed sooner. Sustained data
    // is allowed to build larger files for better upload efficiency.
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
    // Serialize flushes so concurrent stream writes cannot reuse a sequence
    // number or split the queued frame list inconsistently.
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
    final ackFrame = _buildAckFrame();
    if (ackFrame != null) {
      // ACKs are piggybacked onto outgoing chunks when possible to reduce the
      // number of Bale files created for pure control traffic.
      frames.add(ackFrame);
    }
    if (frames.isEmpty) return;
    final ackOnly = frames.every((frame) => frame.type == FrameType.ack);
    final uploadSequence = _nextUploadSequence++;
    final reliableSequence = ackOnly ? 0 : _nextReliableSequence++;
    _logChunkSummary(
      uploadSequence,
      reliableSequence,
      ackOnly,
      frames,
      _targetForFrames(frames),
    );
    final chunk = PlainChunk(
      version: 4,
      sessionId: sessionId,
      direction: sendDirection,
      sequenceNumber: uploadSequence,
      chunkEpoch: chunkEpoch,
      reliableSequenceNumber: reliableSequence,
      ackOnly: ackOnly,
      frames: frames,
    );
    final encrypted = await crypto.encrypt(chunk);
    final bytes = encrypted.encode();
    final fileName = btunFileName(sessionId, sendDirection, uploadSequence);
    // ACK-only chunks are not retried because they acknowledge retry state and
    // do not need their own acknowledgement cycle.
    if (!ackOnly) {
      _cacheRetry(
        reliableSequence,
        uploadSequence: uploadSequence,
        fileName: fileName,
        bytes: bytes,
      );
    }
    try {
      await _sendFile(
        uploadSequence,
        fileName,
        bytes,
        reliableSequence: ackOnly ? null : reliableSequence,
        isAckOnly: ackOnly,
      );
      if (ackFrame != null) {
        _markAckSent(_AckSnapshot(ackFrame.ackNumber, ackFrame.sackRanges));
      }
    } on BtunUploadSuperseded {
      // A newer ACK snapshot replaced this upload before it reached Bale.
    } on Object catch (error) {
      logger.warn('initial send failed for chunk $uploadSequence: $error');
    }
  }

  Future<void> sendFrame(TunnelFrame frame) => sendFrames([frame]);

  int allocateSequence() => _nextFrameSequence++;

  Future<void> _sendFile(
    int sequence,
    String fileName,
    List<int> bytes, {
    required int? reliableSequence,
    required bool isAckOnly,
  }) async {
    await transport.sendFile(
      OutgoingTunnelFile(
        fileName: fileName,
        bytes: bytes,
        sequenceNumber: sequence,
        direction: sendDirection,
        isAckOnly: isAckOnly,
        replaceKey: isAckOnly ? '$sessionId:${sendDirection.name}:ack' : null,
      ),
    );
    if (reliableSequence != null) {
      _retryCache[reliableSequence]?.markSent();
    }
  }

  Future<void> _handleIncoming(IncomingTunnelFile incoming) async {
    try {
      final encrypted = EncryptedChunkFile.decode(incoming.bytes);
      final meta = encrypted.metadata;
      if (meta.sessionId != sessionId || meta.direction != receiveDirection) {
        return;
      }
      if (meta.version != 4) return;
      if (!_matchesAcceptedReceiveEpoch(meta.version, meta.chunkEpoch)) return;
      final chunk = await crypto.decrypt(encrypted);
      if (chunk.sessionId != sessionId || chunk.direction != receiveDirection) {
        return;
      }
      if (!_acceptReceiveEpoch(chunk.version, chunk.chunkEpoch)) return;
      final ackOnly = chunk.ackOnly;
      final receiveSequence = _receiveSequenceFor(chunk);
      final deliveredDuplicate = _deliveredReceivedSequences.contains(
        receiveSequence,
      );
      final bufferedDuplicate = _reorderBuffer.containsKey(receiveSequence);
      // Duplicate chunks can arrive from retries or repeated Bale history
      // polling. They still carry ACKs, but data frames are delivered once.
      var hasDataOrControl = false;
      for (final frame in chunk.frames) {
        if (frame.type == FrameType.ack) {
          _markRetryAcked(frame.ackNumber, frame.sackRanges);
        } else {
          hasDataOrControl = true;
        }
      }
      if (ackOnly) {
        logger.info(
          'received chunk file_seq=${chunk.sequenceNumber} '
          'rel_seq=${chunk.reliableSequenceNumber} ack_only=true '
          'expected=${_nextReceiveSequence?.toString() ?? 'baseline'} '
          'buffered=${_reorderBuffer.length}',
        );
        return;
      }
      final expected = _nextReceiveSequence?.toString() ?? 'baseline';
      logger.info(
        'received chunk file_seq=${chunk.sequenceNumber} '
        'rel_seq=$receiveSequence ack_only=false expected=$expected '
        'buffered=${_reorderBuffer.length} '
        'duplicate=${deliveredDuplicate || bufferedDuplicate}',
      );
      if (!hasDataOrControl) return;
      if (bufferedDuplicate) _scheduleAckRefreshForBufferedDuplicate();
      if (deliveredDuplicate || bufferedDuplicate) return;
      final before = _currentAckSnapshot();
      _bufferOrDeliver(chunk);
      _scheduleAckForStateChange(before);
    } on Object catch (error) {
      logger.warn(
        'ignored corrupted or invalid tunnel file ${incoming.fileName}: $error',
      );
    }
  }

  void _bufferOrDeliver(PlainChunk chunk) {
    final receiveSequence = _receiveSequenceFor(chunk);
    final expected = _nextReceiveSequence;
    if (expected == null) {
      if (receiveSequence == 1) {
        _establishReceiveBaseline(1, reason: 'first chunk');
        _deliverChunk(chunk);
        _drainReorderBuffer();
        return;
      }
      _bufferChunk(chunk);
      _scheduleReceiveBaseline();
      _enforceReorderLimit();
      return;
    }
    if (receiveSequence < expected) {
      logger.info(
        'skipping already delivered chunk file_seq=${chunk.sequenceNumber} '
        'rel_seq=$receiveSequence expected=$expected',
      );
      return;
    }
    if (receiveSequence == expected) {
      _deliverChunk(chunk);
      _drainReorderBuffer();
      return;
    }
    _bufferChunk(chunk);
    logger.warn(
      'holding out-of-order chunk file_seq=${chunk.sequenceNumber} '
      'rel_seq=$receiveSequence expected=$expected '
      'buffered=${_reorderBuffer.length} '
      'bytes=$_reorderBufferBytes gap_age_ms=${_gapAgeMs()}',
    );
    _scheduleReceiveGapTimeout();
    _enforceReorderLimit();
  }

  void _bufferChunk(PlainChunk chunk) {
    final encodedBytes = _estimateChunkBytes(chunk);
    _reorderBuffer[_receiveSequenceFor(chunk)] = _BufferedChunk(
      chunk: chunk,
      estimatedBytes: encodedBytes,
      receivedAt: DateTime.now(),
    );
    _reorderBufferBytes += encodedBytes;
    _receiveGapSince ??= DateTime.now();
  }

  void _scheduleReceiveBaseline() {
    if (_closed || _receiveBaselineTimer != null) return;
    if (receiveBaselineDelay == Duration.zero) {
      _establishReceiveBaselineFromBuffer('initial chunk');
      return;
    }
    _receiveBaselineTimer = Timer(receiveBaselineDelay, () {
      _receiveBaselineTimer = null;
      _establishReceiveBaselineFromBuffer('baseline timeout');
    });
  }

  void _establishReceiveBaselineFromBuffer(String reason) {
    if (_nextReceiveSequence != null || _reorderBuffer.isEmpty) return;
    final baseline = _reorderBuffer.keys.reduce((a, b) => a < b ? a : b);
    _establishReceiveBaseline(baseline, reason: reason);
    _drainReorderBuffer();
  }

  void _establishReceiveBaseline(int sequenceNumber, {required String reason}) {
    _receiveBaselineTimer?.cancel();
    _receiveBaselineTimer = null;
    _nextReceiveSequence = sequenceNumber;
    logger.warn(
      'receive baseline set to chunk $sequenceNumber ($reason); '
      'earlier chunks are unavailable in current receive window',
    );
  }

  void _drainReorderBuffer() {
    var recoveredGap = false;
    while (true) {
      final expected = _nextReceiveSequence;
      if (expected == null) return;
      final buffered = _reorderBuffer.remove(expected);
      if (buffered == null) break;
      _reorderBufferBytes -= buffered.estimatedBytes;
      recoveredGap = true;
      _deliverChunk(buffered.chunk);
    }
    if (recoveredGap) {
      logger.info(
        'recovered receive gap; next_expected=$_nextReceiveSequence '
        'buffered=${_reorderBuffer.length}',
      );
    }
    if (_reorderBuffer.isEmpty) {
      _receiveGapSince = null;
      _receiveGapTimer?.cancel();
      _receiveGapTimer = null;
    } else {
      _receiveGapSince = DateTime.now();
      _scheduleReceiveGapTimeout();
    }
  }

  void _deliverChunk(PlainChunk chunk) {
    final receiveSequence = _receiveSequenceFor(chunk);
    for (final frame in chunk.frames) {
      if (frame.type != FrameType.ack) _frames.add(frame);
    }
    _deliveredReceivedSequences.add(receiveSequence);
    _nextReceiveSequence = receiveSequence + 1;
  }

  void _enforceReorderLimit() {
    final chunkLimit = maxReorderChunks <= 0 ? 1 : maxReorderChunks;
    final byteLimit = maxReorderBytes <= 0 ? chunkSize : maxReorderBytes;
    if (_reorderBuffer.length <= chunkLimit &&
        _reorderBufferBytes <= byteLimit) {
      return;
    }
    logger.warn(
      'receive reorder buffer overflow; closing tunnel '
      'expected=$_nextReceiveSequence buffered=${_reorderBuffer.length} '
      'bytes=$_reorderBufferBytes limits=$chunkLimit/$byteLimit',
    );
    _fatalClose(
      'receive reorder buffer overflow expected=$_nextReceiveSequence',
    );
  }

  void _scheduleReceiveGapTimeout() {
    if (_closed || _nextReceiveSequence == null || _receiveGapTimer != null) {
      return;
    }
    final timeout = receiveGapTimeout;
    if (timeout == null) return;
    if (timeout <= Duration.zero) {
      _closeForReceiveGap();
      return;
    }
    _receiveGapTimer = Timer(timeout, () {
      _receiveGapTimer = null;
      _closeForReceiveGap();
    });
  }

  void _closeForReceiveGap() {
    if (_closed || _reorderBuffer.isEmpty || _nextReceiveSequence == null) {
      return;
    }
    logger.warn(
      'fatal receive-ordering timeout; closing tunnel '
      'expected=$_nextReceiveSequence '
      'buffered=${_reorderBuffer.length} bytes=$_reorderBufferBytes '
      'gap_age_ms=${_gapAgeMs()}',
    );
    _fatalClose('receive gap timed out expected=$_nextReceiveSequence');
  }

  int _estimateChunkBytes(PlainChunk chunk) {
    var bytes = 256;
    for (final frame in chunk.frames) {
      bytes += _estimateFrameBytes(frame);
    }
    return bytes;
  }

  int _gapAgeMs() {
    final since = _receiveGapSince;
    if (since == null) return 0;
    return DateTime.now().difference(since).inMilliseconds;
  }

  void _scheduleAckForStateChange(_AckSnapshot? before) {
    final snapshot = _currentAckSnapshot();
    if (snapshot == null || snapshot == before) return;
    _pendingAckDirty = true;
    _ackElicitingSinceLastAck += 1;
    final sackChanged = before == null
        ? snapshot.sackRanges.isNotEmpty
        : !_sameAckRanges(before.sackRanges, snapshot.sackRanges);
    final urgent =
        sackChanged ||
        snapshot.sackRanges.isNotEmpty ||
        (before != null && before.sackRanges.isNotEmpty);
    if (_queuedFrames.isNotEmpty) {
      _scheduleFlush(_shorterDelay(flushDelay, ackDelay));
      return;
    }
    if (urgent || ackDelay == Duration.zero || _ackElicitingSinceLastAck >= 2) {
      unawaited(flush());
      return;
    }
    _ackTimer ??= Timer(ackDelay, () {
      _ackTimer = null;
      unawaited(flush());
    });
  }

  void _scheduleAckRefreshForBufferedDuplicate() {
    final snapshot = _currentAckSnapshot();
    if (snapshot == null || snapshot.sackRanges.isEmpty) return;
    final sentAt = _lastSentAckAt;
    if (sentAt != null &&
        DateTime.now().difference(sentAt) < _ackRefreshInterval) {
      return;
    }
    _pendingAckDirty = true;
    unawaited(flush());
  }

  Future<void> _retryDue() async {
    if (_closed || _retryInProgress || transport.isBackingOff) return;
    final retryNotBefore = _retryNotBefore;
    if (retryNotBefore != null && DateTime.now().isBefore(retryNotBefore)) {
      return;
    }
    _retryInProgress = true;
    try {
      await _retryDueNow();
    } finally {
      _retryInProgress = false;
    }
  }

  Future<void> _retryDueNow() async {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - retryTimeout.inMilliseconds;
    final retryable =
        _retryCache.values
            .where(
              (record) =>
                  record.lastSentAt == null || record.lastSentAt! < cutoff,
            )
            .toList()
          ..sort((a, b) {
            final sackCompare = (a.sacked ? 1 : 0).compareTo(b.sacked ? 1 : 0);
            if (sackCompare != 0) return sackCompare;
            return a.sequenceNumber.compareTo(b.sequenceNumber);
          });
    for (final record in retryable.take(maxInFlight)) {
      try {
        record.retryCount += 1;
        await transport.sendFile(
          OutgoingTunnelFile(
            fileName: record.fileName,
            bytes: record.bytes,
            sequenceNumber: record.uploadSequenceNumber,
            direction: sendDirection,
          ),
        );
        record.markSent();
      } on BtunAccountTemporarilyUnavailable catch (error) {
        final retryAfter = error.retryAfter;
        if (retryAfter != null) {
          final current = _retryNotBefore;
          if (current == null || retryAfter.isAfter(current)) {
            _retryNotBefore = retryAfter;
          }
        }
        logger.warn(
          'retry paused for chunk rel_seq=${record.sequenceNumber}: $error',
        );
        break;
      } on Object catch (error) {
        logger.warn(
          'retry failed for chunk rel_seq=${record.sequenceNumber}: $error',
        );
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    await flush();
    await _closeInternal('closed');
  }

  void _fatalClose(String reason) {
    if (_closed) return;
    logger.warn('fatal tunnel close: $reason');
    unawaited(_closeInternal(reason));
  }

  Future<void> _closeInternal(String reason) async {
    if (_closed) return;
    _closed = true;
    _closedReason = reason;
    _retryTimer?.cancel();
    _flushTimer?.cancel();
    _ackTimer?.cancel();
    _receiveBaselineTimer?.cancel();
    _receiveGapTimer?.cancel();
    _queuedFrames.clear();
    _queuedBytes = 0;
    _reorderBuffer.clear();
    _reorderBufferBytes = 0;
    _receiveGapSince = null;
    await _incomingSub?.cancel();
    await _frames.close();
  }

  void _throwIfClosed() {
    if (!_closed) return;
    throw ChunkTransportClosedException(_closedReason ?? 'closed');
  }

  void _cacheRetry(
    int sequence, {
    required int uploadSequence,
    required String fileName,
    required List<int> bytes,
  }) {
    final previous = _retryCache.remove(sequence);
    if (previous != null) _retryCacheBytes -= previous.bytes.length;
    _retryCache[sequence] = _RetryChunk(
      sequenceNumber: sequence,
      uploadSequenceNumber: uploadSequence,
      fileName: fileName,
      bytes: List<int>.unmodifiable(bytes),
    );
    _retryCacheBytes += bytes.length;
    _trimRetryCache();
  }

  TunnelFrame? _buildAckFrame() {
    final snapshot = _currentAckSnapshot();
    if (snapshot == null) return null;
    final lastSent = _lastSentAckSnapshot;
    final changed = snapshot != lastSent;
    if (!changed) {
      final sentAt = _lastSentAckAt;
      final refreshDue =
          sentAt == null ||
          DateTime.now().difference(sentAt) >= _ackRefreshInterval;
      if (!_pendingAckDirty || !refreshDue) return null;
    }
    return TunnelFrame.ack(
      sessionId: sessionId,
      direction: sendDirection,
      ackNumber: snapshot.ackNumber,
      sackRanges: snapshot.sackRanges,
    );
  }

  _AckSnapshot? _currentAckSnapshot() {
    final ackNumber = (_nextReceiveSequence ?? 1) - 1;
    if (ackNumber <= 0 && _reorderBuffer.isEmpty) {
      return null;
    }
    return _AckSnapshot(ackNumber < 0 ? 0 : ackNumber, _sackRanges());
  }

  void _markAckSent(_AckSnapshot snapshot) {
    _lastSentAckSnapshot = snapshot;
    _lastSentAckAt = DateTime.now();
    _pendingAckDirty = false;
    _ackElicitingSinceLastAck = 0;
    _ackTimer?.cancel();
    _ackTimer = null;
  }

  Duration get _ackRefreshInterval {
    final delayMs = ackDelay.inMilliseconds * 4;
    final minimumMs = const Duration(seconds: 5).inMilliseconds;
    return Duration(milliseconds: delayMs > minimumMs ? delayMs : minimumMs);
  }

  List<AckRange> _sackRanges() {
    if (_reorderBuffer.isEmpty) return const <AckRange>[];
    final keys = _reorderBuffer.keys.toList()..sort();
    final ranges = <AckRange>[];
    var start = keys.first;
    var end = start;
    for (final key in keys.skip(1)) {
      if (key == end + 1) {
        end = key;
      } else {
        ranges.add(AckRange(start: start, end: end));
        start = key;
        end = key;
      }
    }
    ranges.add(AckRange(start: start, end: end));
    return ranges.reversed.take(8).toList(growable: false);
  }

  bool _sameAckRanges(List<AckRange> a, List<AckRange> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i].start != b[i].start || a[i].end != b[i].end) return false;
    }
    return true;
  }

  bool _acceptReceiveEpoch(int version, String? epoch) {
    if (version != 4) return false;
    final chunkEpoch = epoch;
    if (chunkEpoch == null || chunkEpoch.isEmpty) return false;
    final accepted = _receiveChunkEpoch;
    if (accepted == null) {
      _receiveChunkEpoch = chunkEpoch;
      return true;
    }
    if (accepted == chunkEpoch) return true;
    logger.info('ignored chunk from stale epoch $chunkEpoch');
    return false;
  }

  bool _matchesAcceptedReceiveEpoch(int version, String? epoch) {
    if (version != 4) return false;
    final accepted = _receiveChunkEpoch;
    if (accepted == null) return true;
    return epoch == accepted;
  }

  void _markRetryAcked(int ackNumber, List<AckRange> sackRanges) {
    final acked = _retryCache.keys.where((sequence) => sequence <= ackNumber);
    for (final sequence in acked.toList()) {
      final removed = _retryCache.remove(sequence);
      if (removed != null) _retryCacheBytes -= removed.bytes.length;
    }
    for (final range in sackRanges) {
      for (final record in _retryCache.values) {
        if (record.sequenceNumber >= range.start &&
            record.sequenceNumber <= range.end) {
          record.sacked = true;
        }
      }
    }
    _scheduleSackGapProbe(ackNumber, sackRanges);
  }

  void _scheduleSackGapProbe(int ackNumber, List<AckRange> sackRanges) {
    if (sackRanges.isEmpty) return;
    final highestSacked = sackRanges
        .map((range) => range.end)
        .reduce((a, b) => a > b ? a : b);
    _RetryChunk? probe;
    for (final record in _retryCache.values) {
      if (record.sequenceNumber <= ackNumber ||
          record.sequenceNumber > highestSacked ||
          record.sacked) {
        continue;
      }
      if (probe == null || record.sequenceNumber < probe.sequenceNumber) {
        probe = record;
      }
    }
    final record = probe;
    if (record == null || record.lossProbeScheduled) return;
    final scheduled = _retryCache.values.where(
      (candidate) => candidate.lossProbeScheduled,
    );
    if (scheduled.length >= maxInFlight) return;
    record.lossProbeScheduled = true;
    final delay = _lossProbeDelay;
    logger.info(
      'loss probe rel_seq=${record.sequenceNumber} reason=sack_gap '
      'highest_sacked=$highestSacked delay_ms=${delay.inMilliseconds}',
    );
    Timer(delay, () {
      unawaited(_sendLossProbe(record, highestSacked));
    });
  }

  Duration get _lossProbeDelay {
    final doubledAckDelay = ackDelay * 2;
    final floor = const Duration(seconds: 1);
    final cap = const Duration(seconds: 10);
    if (doubledAckDelay < floor) return floor;
    if (doubledAckDelay > cap) return cap;
    return doubledAckDelay;
  }

  Future<void> _sendLossProbe(_RetryChunk record, int highestSacked) async {
    record.lossProbeScheduled = false;
    if (_closed ||
        transport.isBackingOff ||
        !_retryCache.containsKey(record.sequenceNumber)) {
      return;
    }
    try {
      logger.info(
        'loss probe rel_seq=${record.sequenceNumber} reason=sack_gap '
        'highest_sacked=$highestSacked',
      );
      record.retryCount += 1;
      await transport.sendFile(
        OutgoingTunnelFile(
          fileName: record.fileName,
          bytes: record.bytes,
          sequenceNumber: record.uploadSequenceNumber,
          direction: sendDirection,
        ),
      );
      record.markSent();
    } on BtunAccountTemporarilyUnavailable catch (error) {
      final retryAfter = error.retryAfter;
      if (retryAfter != null) {
        final current = _retryNotBefore;
        if (current == null || retryAfter.isAfter(current)) {
          _retryNotBefore = retryAfter;
        }
      }
      logger.warn(
        'loss probe paused for chunk rel_seq=${record.sequenceNumber}: $error',
      );
    } on Object catch (error) {
      logger.warn(
        'loss probe failed for chunk rel_seq=${record.sequenceNumber}: $error',
      );
    }
  }

  void _trimRetryCache() {
    final chunkLimit = maxRetryChunks <= 0 ? 1 : maxRetryChunks;
    final byteLimit = maxRetryBytes <= 0 ? chunkSize : maxRetryBytes;
    while (_retryCache.length > chunkLimit || _retryCacheBytes > byteLimit) {
      // Dropping the oldest retry record is preferable to unbounded memory use
      // when the peer or Bale transport is unavailable for an extended period.
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

  int _receiveSequenceFor(PlainChunk chunk) {
    return chunk.reliableSequenceNumber;
  }

  void _logChunkSummary(
    int uploadSequence,
    int reliableSequence,
    bool ackOnly,
    List<TunnelFrame> frames,
    int target,
  ) {
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
      'chunk file_seq=$uploadSequence rel_seq=$reliableSequence '
      'ack_only=$ackOnly frames=${frames.length} types=$types '
      'payload=$payloadBytes mode=${(mode ?? _ChunkMode.steady).name} '
      'target=$target',
    );
  }
}

enum _ChunkMode { interactive, steady, bulk }

class _AckSnapshot {
  _AckSnapshot(this.ackNumber, List<AckRange> sackRanges)
    : sackRanges = List<AckRange>.unmodifiable(sackRanges);

  final int ackNumber;
  final List<AckRange> sackRanges;

  @override
  bool operator ==(Object other) {
    if (other is! _AckSnapshot || ackNumber != other.ackNumber) return false;
    if (sackRanges.length != other.sackRanges.length) return false;
    for (var i = 0; i < sackRanges.length; i += 1) {
      final a = sackRanges[i];
      final b = other.sackRanges[i];
      if (a.start != b.start || a.end != b.end) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = ackNumber.hashCode;
    for (final range in sackRanges) {
      hash = Object.hash(hash, range.start, range.end);
    }
    return hash;
  }
}

class _StreamChunkState {
  _StreamChunkState(DateTime now) : firstDataAt = now, lastDataAt = now;

  DateTime firstDataAt;
  DateTime lastDataAt;
  var frameCount = 0;
  var totalBytes = 0;
  _ChunkMode mode = _ChunkMode.interactive;

  void update(int bytes, DateTime now, ChunkTransport transport) {
    if (now.difference(lastDataAt) >= transport.streamIdleTimeout) {
      // After an idle gap, treat the next bytes as interactive again so a fresh
      // page load or command does not wait behind bulk cadence.
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
    required this.uploadSequenceNumber,
    required this.fileName,
    required this.bytes,
  });

  final int sequenceNumber;
  final int uploadSequenceNumber;
  final String fileName;
  final List<int> bytes;
  int retryCount = 0;
  int? lastSentAt;
  bool sacked = false;
  bool lossProbeScheduled = false;

  void markSent() {
    lastSentAt = DateTime.now().millisecondsSinceEpoch;
  }
}

String _newChunkEpoch() {
  final random = Random.secure();
  final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final salt = List<int>.generate(
    8,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '$micros$salt';
}

class _BufferedChunk {
  const _BufferedChunk({
    required this.chunk,
    required this.estimatedBytes,
    required this.receivedAt,
  });

  final PlainChunk chunk;
  final int estimatedBytes;
  final DateTime receivedAt;
}

class ChunkTransportClosedException implements Exception {
  const ChunkTransportClosedException(this.reason);

  final String reason;

  @override
  String toString() => 'ChunkTransportClosedException: $reason';
}
