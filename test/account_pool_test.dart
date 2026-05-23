import 'dart:async';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('config account helpers upsert remove and enable accounts', () {
    final first = const BtunAccountConfig(
      userId: 11,
      sessionFile: '.btun/accounts/11.session.json',
    );
    final second = const BtunAccountConfig(
      userId: 22,
      sessionFile: '.btun/accounts/22.session.json',
    );

    var config = BtunConfig.defaults(
      profileDir: '.btun',
    ).upsertAccount(first).upsertAccount(second);

    expect(config.accounts.map((account) => account.userId), [11, 22]);

    config = config.setAccountEnabled(11, false);
    expect(config.enabledAccounts.map((account) => account.userId), [22]);

    config = config.removeAccount(22);
    expect(config.accounts.single.userId, 11);
  });

  test('load balanced transport sends files round robin', () async {
    final first = _FakeTransport();
    final second = _FakeTransport();
    final transport = LoadBalancedSavedMessagesTransport(
      transports: [first, second],
      logger: const Logger(),
    );
    await transport.start();

    for (var i = 0; i < 4; i++) {
      await transport.sendFile(
        OutgoingTunnelFile(
          fileName: 'file-$i',
          bytes: [i],
          sequenceNumber: i,
          direction: Direction.c2r,
        ),
      );
    }

    expect(first.sent.map((file) => file.sequenceNumber), [0, 2]);
    expect(second.sent.map((file) => file.sequenceNumber), [1, 3]);
    await transport.close();
  });

  test(
    'load balanced transport can add and remove accounts while running',
    () async {
      final first = _FakeTransport();
      final second = _FakeTransport();
      final transport = LoadBalancedSavedMessagesTransport(
        transports: [first],
        logger: const Logger(),
      );
      await transport.start();
      await transport.addAccount(22, second);

      for (var i = 0; i < 4; i++) {
        await transport.sendFile(
          OutgoingTunnelFile(
            fileName: 'file-$i',
            bytes: [i],
            sequenceNumber: i,
            direction: Direction.c2r,
          ),
        );
      }

      expect(first.sent.map((file) => file.sequenceNumber), [0, 2]);
      expect(second.sent.map((file) => file.sequenceNumber), [1, 3]);

      await transport.removeAccount(22);
      await transport.sendFile(
        const OutgoingTunnelFile(
          fileName: 'file-4',
          bytes: [4],
          sequenceNumber: 4,
          direction: Direction.c2r,
        ),
      );

      expect(first.sent.map((file) => file.sequenceNumber), [0, 2, 4]);
      expect(second.sent.map((file) => file.sequenceNumber), [1, 3]);
      expect(second.closed, isTrue);
      await transport.close();
    },
  );

  test('config diff classifies live and rebuild changes', () {
    final base = BtunConfig.defaults(profileDir: '.btun').copyWith(
      database: '.btun/state.json',
      sessionId: 'session',
      localPublicKey: 'local-public',
      localPrivateKey: 'local-private',
      peerPublicKey: 'peer-public',
    );

    final live = BtunConfigDiff.compare(
      base,
      base.copyWith(uploadRateLimitPerMinute: 30),
    );
    expect(live.mode, BtunConfigReloadMode.live);
    expect(live.reasons, contains('account transport tuning'));

    final accountLive = BtunConfigDiff.compare(
      base,
      base.upsertAccount(
        const BtunAccountConfig(
          userId: 7,
          sessionFile: '.btun/accounts/7.session.json',
        ),
      ),
    );
    expect(accountLive.mode, BtunConfigReloadMode.live);
    expect(accountLive.reasons, contains('accounts'));

    final rebuild = BtunConfigDiff.compare(
      base,
      base.copyWith(sessionId: 'next-session'),
    );
    expect(rebuild.mode, BtunConfigReloadMode.rebuild);
    expect(rebuild.reasons, contains('session id'));
  });
}

class _FakeTransport implements TunnelTransport {
  final sent = <OutgoingTunnelFile>[];
  final incoming = StreamController<IncomingTunnelFile>.broadcast();
  var closed = false;

  @override
  bool get isBackingOff => false;

  @override
  Future<void> start() async {}

  @override
  Stream<IncomingTunnelFile> incomingFiles() => incoming.stream;

  @override
  Future<void> sendFile(OutgoingTunnelFile file) async {
    sent.add(file);
  }

  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }
}
