import 'dart:async';

import 'package:bale_client/bale_client.dart';

import 'logger.dart';
import 'protocol.dart';
import 'state_db.dart';
import 'tunnel_transport.dart';

class BaleSavedMessagesTransport implements TunnelTransport {
  BaleSavedMessagesTransport({
    required this.client,
    required this.sessionId,
    required this.sendDirection,
    required this.receiveDirection,
    required this.pollInterval,
    required this.stateDb,
    required this.uploadMinInterval,
    required this.uploadRateLimitPerMinute,
    required this.logger,
    this.maxConcurrentUploads = 1,
    this.accountUserId,
  });

  final BaleClient client;
  final String sessionId;
  final Direction sendDirection;
  final Direction receiveDirection;
  final Duration pollInterval;
  final StateDb stateDb;
  final Duration uploadMinInterval;
  final int uploadRateLimitPerMinute;
  final Logger logger;
  final int maxConcurrentUploads;
  final int? accountUserId;

  final StreamController<IncomingTunnelFile> _incoming =
      StreamController<IncomingTunnelFile>.broadcast();
  StreamSubscription<BaleUpdate>? _updates;
  Timer? _pollTimer;
  bool _polling = false;
  DateTime? _backoffUntil;
  var _rateLimitFailures = 0;
  Completer<void>? _backoffCompleter;
  Object? _backoffToken;
  final _pendingUploads = <_QueuedUpload>[];
  var _activeUploads = 0;
  DateTime? _lastUploadAt;
  final _queuedUploads = <int, Future<void>>{};
  final _downloadRetryAfter = <String, DateTime>{};
  final _uploadWindow = <DateTime>[];
  Future<void> _uploadSlotTail = Future.value();
  var _adaptiveUploadRateLimit = 0;
  var _rateLimitEvents = 0;
  var _transientHttpEvents = 0;
  Timer? _uploadRateRecoveryTimer;

  @override
  bool get isBackingOff {
    final until = _backoffUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  BalePeer get _savedMessagesPeer {
    final userId = client.session?.userId;
    if (userId == null) throw Exception('Bale session has no userId');
    return BalePeer.private(userId);
  }

  @override
  Future<void> start() async {
    _updates = client.updates.listen((update) {
      if (update case BaleMessageUpdate(:final message)) {
        unawaited(_maybeDownload(message));
      }
    });
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  @override
  Stream<IncomingTunnelFile> incomingFiles() => _incoming.stream;

  @override
  Future<void> sendFile(OutgoingTunnelFile file) async {
    final existing = _queuedUploads[file.sequenceNumber];
    if (existing != null) return existing;
    logger.info(
      'queued upload seq=${file.sequenceNumber} bytes=${file.bytes.length}',
    );
    final upload = _QueuedUpload(file);
    final current = upload.completer.future;
    _queuedUploads[file.sequenceNumber] = current;
    unawaited(
      current
          .whenComplete(() {
            _queuedUploads.remove(file.sequenceNumber);
          })
          .catchError((_) {}),
    );
    _pendingUploads.add(upload);
    _pumpUploads();
    return current;
  }

  void _pumpUploads() {
    final limit = maxConcurrentUploads <= 0 ? 1 : maxConcurrentUploads;
    while (_activeUploads < limit && _pendingUploads.isNotEmpty) {
      final upload = _pendingUploads.removeAt(0);
      _activeUploads += 1;
      unawaited(() async {
        try {
          await _sendFileNow(upload.file);
          if (!upload.completer.isCompleted) upload.completer.complete();
        } on Object catch (error, stack) {
          logger.warn(
            'upload failed seq=${upload.file.sequenceNumber}: $error',
          );
          if (!upload.completer.isCompleted) {
            upload.completer.completeError(error, stack);
          }
        } finally {
          _activeUploads -= 1;
          _pumpUploads();
        }
      }());
    }
  }

  Future<void> _sendFileNow(OutgoingTunnelFile file) async {
    await _withRateLimitBackoff('send ${file.fileName}', () async {
      await _reserveUploadAttempt();
      return client.sendDocument(
        peer: _savedMessagesPeer,
        file: BaleFileInput.bytes(
          file.bytes,
          name: file.fileName,
          mimeType: 'application/octet-stream',
        ),
      );
    });
    logger.info(
      'sent upload seq=${file.sequenceNumber} bytes=${file.bytes.length}',
    );
    _logUploadWindowStats();
  }

  Future<void> _reserveUploadAttempt() {
    final reservation = _uploadSlotTail.then((_) async {
      await _waitForUploadPace();
      await _waitForUploadRateSlot();
      _recordUploadAttempt();
      _lastUploadAt = DateTime.now();
    });
    _uploadSlotTail = reservation.catchError((_) {});
    return reservation;
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final messages = await _withRateLimitBackoff(
        'poll Saved Messages',
        () => client.loadHistory(peer: _savedMessagesPeer, limit: 30),
      );
      for (final message in messages.reversed) {
        await _maybeDownload(message);
      }
    } on Object catch (error) {
      logger.warn('Saved Messages poll failed: $error');
    } finally {
      _polling = false;
    }
  }

  Future<void> _maybeDownload(BaleMessage message) async {
    final document = message.document;
    if (document == null) return;
    if (!isBtunFileName(document.name)) return;
    if (!_nameMatches(document.name)) return;
    final messageId = accountUserId == null
        ? message.messageId.toString()
        : '$accountUserId:${message.messageId}';
    if (stateDb.hasProcessedMessage(messageId)) return;
    final retryAfter = _downloadRetryAfter[messageId];
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) return;
    try {
      final bytes = await _withRateLimitBackoff(
        'download ${document.name}',
        () => client.downloadFile(
          fileId: document.fileId,
          accessHash: document.accessHash,
        ),
      );
      _downloadRetryAfter.remove(messageId);
      stateDb.markProcessedMessage(messageId);
      _incoming.add(
        IncomingTunnelFile(
          messageId: messageId,
          fileName: document.name,
          bytes: bytes,
        ),
      );
    } on Object catch (error) {
      _downloadRetryAfter[messageId] = DateTime.now().add(
        const Duration(seconds: 60),
      );
      logger.warn('download failed for message ${message.messageId}: $error');
    }
  }

  bool _nameMatches(String name) {
    final prefix = 'btun_${sessionId}_${receiveDirection.name}_';
    return name.startsWith(prefix);
  }

  Future<T> _withRateLimitBackoff<T>(
    String operation,
    Future<T> Function() action,
  ) async {
    while (true) {
      await _waitForBackoff();
      try {
        final result = await action();
        _rateLimitFailures = 0;
        return result;
      } on Object catch (error) {
        if (isBaleRateLimit(error)) {
          _startBackoff(operation, error, rateLimit: true);
          continue;
        }
        if (isBaleTransientHttpError(error)) {
          _startBackoff(operation, error, rateLimit: false);
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _waitForBackoff() async {
    while (isBackingOff) {
      final completer = _backoffCompleter;
      if (completer != null) await completer.future;
    }
  }

  Future<void> _waitForUploadPace() async {
    final last = _lastUploadAt;
    if (last == null || uploadMinInterval == Duration.zero) return;
    final elapsed = DateTime.now().difference(last);
    final remaining = uploadMinInterval - elapsed;
    if (!remaining.isNegative && remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }
  }

  Future<void> _waitForUploadRateSlot() async {
    while (true) {
      final now = DateTime.now();
      _dropExpiredUploadAttempts(now);
      final limit = _currentUploadRateLimit;
      if (limit <= 0 || _uploadWindow.length < limit) return;
      final delay = _uploadWindow.first
          .add(const Duration(minutes: 1))
          .difference(now);
      if (delay > Duration.zero) {
        logger.warn(
          'upload rate limit ${_uploadWindow.length}/$limit per minute; '
          'waiting ${delay.inSeconds}s',
        );
        await Future<void>.delayed(delay);
      } else {
        _dropExpiredUploadAttempts(DateTime.now());
      }
    }
  }

  void _recordUploadAttempt() {
    final now = DateTime.now();
    _dropExpiredUploadAttempts(now);
    _uploadWindow.add(now);
  }

  void _dropExpiredUploadAttempts(DateTime now) {
    final cutoff = now.subtract(const Duration(minutes: 1));
    while (_uploadWindow.isNotEmpty && _uploadWindow.first.isBefore(cutoff)) {
      _uploadWindow.removeAt(0);
    }
  }

  int get _currentUploadRateLimit {
    if (_adaptiveUploadRateLimit > 0) return _adaptiveUploadRateLimit;
    return uploadRateLimitPerMinute;
  }

  void _lowerUploadRateLimit() {
    final base = uploadRateLimitPerMinute <= 0 ? 1 : uploadRateLimitPerMinute;
    final current = _currentUploadRateLimit <= 0
        ? base
        : _currentUploadRateLimit;
    _adaptiveUploadRateLimit = (current / 2).floor().clamp(1, base).toInt();
    _uploadRateRecoveryTimer?.cancel();
    _uploadRateRecoveryTimer = Timer(const Duration(minutes: 2), () {
      if (_adaptiveUploadRateLimit <= 0) return;
      _adaptiveUploadRateLimit = (_adaptiveUploadRateLimit + 5)
          .clamp(1, base)
          .toInt();
      if (_adaptiveUploadRateLimit >= base) {
        _adaptiveUploadRateLimit = 0;
        _uploadRateRecoveryTimer = null;
      } else {
        _lowerUploadRateRecoveryOnly(base);
      }
    });
    logger.warn(
      'adaptive upload rate lowered to $_adaptiveUploadRateLimit/min',
    );
  }

  void _lowerUploadRateRecoveryOnly(int base) {
    _uploadRateRecoveryTimer?.cancel();
    _uploadRateRecoveryTimer = Timer(const Duration(minutes: 2), () {
      _adaptiveUploadRateLimit = (_adaptiveUploadRateLimit + 5)
          .clamp(1, base)
          .toInt();
      if (_adaptiveUploadRateLimit >= base) {
        _adaptiveUploadRateLimit = 0;
        _uploadRateRecoveryTimer = null;
      } else {
        _lowerUploadRateRecoveryOnly(base);
      }
    });
  }

  void _logUploadWindowStats() {
    final now = DateTime.now();
    _dropExpiredUploadAttempts(now);
    final limit = _currentUploadRateLimit;
    logger.info(
      'upload window files=${_uploadWindow.length}/$limit per minute',
    );
  }

  void _startBackoff(
    String operation,
    Object error, {
    required bool rateLimit,
  }) {
    if (rateLimit) {
      _rateLimitFailures += 1;
      _rateLimitEvents += 1;
    } else {
      _transientHttpEvents += 1;
    }
    if (rateLimit && operation.startsWith('send ')) {
      _lowerUploadRateLimit();
    }
    final seconds = rateLimit
        ? switch (_rateLimitFailures) {
            1 => 15,
            2 => 30,
            3 => 60,
            _ => 120,
          }
        : 60;
    final until = DateTime.now().add(Duration(seconds: seconds));
    final current = _backoffUntil;
    if (current == null || until.isAfter(current)) {
      _backoffUntil = until;
      final token = Object();
      _backoffToken = token;
      _backoffCompleter = Completer<void>();
      Timer(Duration(seconds: seconds), () {
        if (_backoffToken != token) return;
        final completer = _backoffCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete();
        }
        _backoffCompleter = null;
        _backoffToken = null;
      });
      final reason = rateLimit ? 'rate limited' : 'HTTP 500/transient error';
      logger.warn(
        'Bale $reason during $operation; backing off ${seconds}s '
        '(rate_limits=$_rateLimitEvents transient_http=$_transientHttpEvents)',
      );
    } else {
      logger.warn(
        'Bale operation failed during $operation; already backing off',
      );
    }
  }

  @override
  Future<void> close() async {
    _pollTimer?.cancel();
    _uploadRateRecoveryTimer?.cancel();
    await _updates?.cancel();
    await _incoming.close();
  }
}

class LoadBalancedSavedMessagesTransport implements TunnelTransport {
  LoadBalancedSavedMessagesTransport({
    required List<TunnelTransport> transports,
    required this.logger,
  }) : _transports = transports;

  final List<TunnelTransport> _transports;
  final Logger logger;
  final StreamController<IncomingTunnelFile> _incoming =
      StreamController<IncomingTunnelFile>.broadcast();
  final _subscriptions = <StreamSubscription<IncomingTunnelFile>>[];
  var _nextUploadIndex = 0;
  var _started = false;

  @override
  bool get isBackingOff =>
      _transports.isNotEmpty &&
      _transports.every((transport) => transport.isBackingOff);

  @override
  Future<void> start() async {
    if (_transports.isEmpty) {
      throw Exception('no enabled Bale accounts; add an account first');
    }
    if (_started) return;
    _started = true;
    for (final transport in _transports) {
      _subscriptions.add(
        transport.incomingFiles().listen(
          _incoming.add,
          onError: _incoming.addError,
        ),
      );
      await transport.start();
    }
  }

  @override
  Stream<IncomingTunnelFile> incomingFiles() => _incoming.stream;

  @override
  Future<void> sendFile(OutgoingTunnelFile file) async {
    if (_transports.isEmpty) {
      throw Exception('no enabled Bale accounts; add an account first');
    }
    Object? lastError;
    for (var attempt = 0; attempt < _transports.length; attempt++) {
      final index = (_nextUploadIndex + attempt) % _transports.length;
      final transport = _transports[index];
      if (transport.isBackingOff && attempt < _transports.length - 1) {
        continue;
      }
      try {
        await transport.sendFile(file);
        _nextUploadIndex = (index + 1) % _transports.length;
        return;
      } on Object catch (error) {
        lastError = error;
        logger.warn('account upload failed; trying next account: $error');
      }
    }
    if (lastError != null) throw lastError;
  }

  @override
  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final transport in _transports) {
      await transport.close();
    }
    await _incoming.close();
  }
}

class _QueuedUpload {
  _QueuedUpload(this.file);

  final OutgoingTunnelFile file;
  final completer = Completer<void>();
}

bool isBaleRateLimit(Object error) {
  if (error is BaleException && error.code == 8) return true;
  return error.toString().contains('user_rate_limited');
}

bool isBaleTransientHttpError(Object error) {
  final text = error.toString();
  return text.contains('HTTP 500') ||
      text.contains('HTTP 502') ||
      text.contains('HTTP 503') ||
      text.contains('HTTP 504');
}
