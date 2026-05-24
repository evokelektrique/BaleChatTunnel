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

  test('load balanced transport skips accounts that are backing off', () async {
    final first = _FakeTransport(
      backoffUntil: DateTime.now().add(const Duration(minutes: 1)),
    );
    final second = _FakeTransport();
    final transport = LoadBalancedSavedMessagesTransport(
      transports: [first, second],
      logger: const Logger(),
    );
    await transport.start();

    await transport.sendFile(
      const OutgoingTunnelFile(
        fileName: 'file-1',
        bytes: [1],
        sequenceNumber: 1,
        direction: Direction.c2r,
      ),
    );

    expect(first.sent, isEmpty);
    expect(second.sent.map((file) => file.sequenceNumber), [1]);
    await transport.close();
  });

  test(
    'load balanced transport retries same file after temporary account failure',
    () async {
      final first = _FakeTransport(
        temporaryFailure: const BtunAccountTemporarilyUnavailable(
          operation: 'send file-1',
          reason: 'rate limited',
          accountUserId: 11,
        ),
      );
      final second = _FakeTransport();
      final transport = LoadBalancedSavedMessagesTransport(
        transports: [first, second],
        logger: const Logger(),
      );
      await transport.start();

      await transport.sendFile(
        const OutgoingTunnelFile(
          fileName: 'file-1',
          bytes: [1],
          sequenceNumber: 1,
          direction: Direction.c2r,
        ),
      );

      expect(first.sent.map((file) => file.sequenceNumber), [1]);
      expect(second.sent.map((file) => file.sequenceNumber), [1]);
      await transport.close();
    },
  );

  test(
    'load balanced transport fails temporarily when all accounts back off',
    () async {
      final first = _FakeTransport(
        backoffUntil: DateTime.now().add(const Duration(minutes: 1)),
      );
      final second = _FakeTransport(
        backoffUntil: DateTime.now().add(const Duration(minutes: 2)),
      );
      final transport = LoadBalancedSavedMessagesTransport(
        transports: [first, second],
        logger: const Logger(),
      );
      await transport.start();

      await expectLater(
        transport.sendFile(
          const OutgoingTunnelFile(
            fileName: 'file-1',
            bytes: [1],
            sequenceNumber: 1,
            direction: Direction.c2r,
          ),
        ),
        throwsA(isA<BtunAccountTemporarilyUnavailable>()),
      );
      await transport.close();
    },
  );

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
  _FakeTransport({this.backoffUntil, this.temporaryFailure});

  final sent = <OutgoingTunnelFile>[];
  final incoming = StreamController<IncomingTunnelFile>.broadcast();
  final BtunAccountTemporarilyUnavailable? temporaryFailure;
  var closed = false;

  @override
  DateTime? backoffUntil;

  @override
  bool get isBackingOff {
    final until = backoffUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  @override
  Future<void> start() async {}

  @override
  Stream<IncomingTunnelFile> incomingFiles() => incoming.stream;

  @override
  Future<void> sendFile(OutgoingTunnelFile file) async {
    sent.add(file);
    final failure = temporaryFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }
}
