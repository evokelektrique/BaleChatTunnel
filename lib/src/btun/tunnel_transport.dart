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

abstract interface class TunnelTransport {
  Future<void> start();
  Stream<IncomingTunnelFile> incomingFiles();
  Future<void> sendFile(OutgoingTunnelFile file);
  bool get isBackingOff;
  Future<void> close();
}
