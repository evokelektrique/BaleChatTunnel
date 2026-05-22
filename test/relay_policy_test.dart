import 'dart:io';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('relay policy blocks private IPv4 ranges', () {
    final policy = RelayPolicy(
      allowPorts: {80, 443},
      blockPrivateIps: true,
      dnsOnRelay: true,
    );

    expect(policy.isBlocked(InternetAddress('127.0.0.1')), isTrue);
    expect(policy.isBlocked(InternetAddress('10.1.2.3')), isTrue);
    expect(policy.isBlocked(InternetAddress('172.16.0.1')), isTrue);
    expect(policy.isBlocked(InternetAddress('192.168.1.1')), isTrue);
    expect(policy.isBlocked(InternetAddress('169.254.169.254')), isTrue);
    expect(policy.isBlocked(InternetAddress('93.184.216.34')), isFalse);
  });

  test('relay policy blocks local IPv6 ranges', () {
    final policy = RelayPolicy(
      allowPorts: {80, 443},
      blockPrivateIps: true,
      dnsOnRelay: true,
    );

    expect(policy.isBlocked(InternetAddress('::1')), isTrue);
    expect(policy.isBlocked(InternetAddress('fc00::1')), isTrue);
    expect(policy.isBlocked(InternetAddress('fe80::1')), isTrue);
    expect(
      policy.isBlocked(InternetAddress('2606:2800:220:1:248:1893:25c8:1946')),
      isFalse,
    );
  });
}
