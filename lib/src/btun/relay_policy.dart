import 'dart:io';

import 'config.dart';

class RelayPolicy {
  RelayPolicy({
    required this.allowPorts,
    required this.blockPrivateIps,
    required this.dnsOnRelay,
  });

  final Set<int> allowPorts;
  final bool blockPrivateIps;
  final bool dnsOnRelay;

  factory RelayPolicy.fromConfig(BtunConfig config) => RelayPolicy(
    allowPorts: config.allowPorts.toSet(),
    blockPrivateIps: config.blockPrivateIps,
    dnsOnRelay: config.dnsOnRelay,
  );

  Future<List<InternetAddress>> resolveAllowed(String host, int port) async {
    if (!allowPorts.contains(port)) {
      throw RelayPolicyException('port $port is not allowed');
    }
    final addresses = await InternetAddress.lookup(host);
    final allowed = addresses.where((address) => !isBlocked(address)).toList();
    if (allowed.isEmpty) {
      throw RelayPolicyException('target resolves only to blocked addresses');
    }
    return allowed;
  }

  bool isBlocked(InternetAddress address) {
    if (!blockPrivateIps) return false;
    final raw = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = raw[0];
      final b = raw[1];
      if (a == 10 || a == 127) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      if (a == 169 && b == 254) return true;
      if (a == 169 && b == 254 && raw[2] == 169 && raw[3] == 254) return true;
      return false;
    }
    if (raw.every((b) => b == 0)) return true;
    if (raw.take(15).every((b) => b == 0) && raw.last == 1) return true;
    final first = raw[0];
    final second = raw[1];
    if ((first & 0xfe) == 0xfc) return true;
    if (first == 0xfe && (second & 0xc0) == 0x80) return true;
    return false;
  }
}

class RelayPolicyException implements Exception {
  const RelayPolicyException(this.message);

  final String message;

  @override
  String toString() => message;
}
