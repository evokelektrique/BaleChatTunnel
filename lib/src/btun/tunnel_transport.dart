import 'protocol.dart';

class IncomingTunnelFile {
  const IncomingTunnelFile({
    required this.messageId,
    required this.fileName,
    required this.bytes,
  });

  final String messageId;
  final String fileName;
  final List<int> bytes;
}

class OutgoingTunnelFile {
  const OutgoingTunnelFile({
    required this.fileName,
    required this.bytes,
    required this.sequenceNumber,
    required this.direction,
  });

  final String fileName;
  final List<int> bytes;
  final int sequenceNumber;
  final Direction direction;
}

class TunnelTrafficDelta {
  const TunnelTrafficDelta({this.uploadedBytes = 0, this.downloadedBytes = 0});

  final int uploadedBytes;
  final int downloadedBytes;
}

typedef TunnelTrafficCallback = void Function(TunnelTrafficDelta delta);

abstract interface class TunnelTransport {
  Future<void> start();
  Stream<IncomingTunnelFile> incomingFiles();
  Future<void> sendFile(OutgoingTunnelFile file);
  bool get isBackingOff;
  DateTime? get backoffUntil;
  Future<void> close();
}

class BtunAccountTemporarilyUnavailable implements Exception {
  const BtunAccountTemporarilyUnavailable({
    required this.operation,
    required this.reason,
    this.accountUserId,
    this.retryAfter,
    this.cause,
  });

  final String operation;
  final String reason;
  final int? accountUserId;
  final DateTime? retryAfter;
  final Object? cause;

  @override
  String toString() {
    final account = accountUserId == null ? '' : ' account=$accountUserId';
    final retry = retryAfter == null
        ? ''
        : ' backoff_until=${retryAfter!.toIso8601String()}';
    return 'temporary Bale account failure$account during $operation: '
        '$reason$retry';
  }
}
