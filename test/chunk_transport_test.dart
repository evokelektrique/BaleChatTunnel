import 'dart:async';
import 'dart:io';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:bale_client/bale_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chunk transport batches frames until flush', () async {
    final temp = await Directory.systemTemp.createTemp('btun_chunk_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      chunkSize: 1024 * 1024,
    );
    final transport = _FakeTransport();
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: await BtunCrypto.fromConfig(
        config,
        send: Direction.c2r,
        receive: Direction.r2c,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: config.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: config.chunkSize,
      retryTimeout: const Duration(minutes: 1),
      maxInFlight: 1,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      interactiveFlushDelay: const Duration(minutes: 1),
      controlFlushDelay: const Duration(minutes: 1),
      ackDelay: const Duration(minutes: 1),
    );
    await chunkTransport.start();

    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: [1, 2, 3],
      ),
    );
    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 2,
        payload: [4, 5, 6],
      ),
    );

    expect(transport.sent, isEmpty);
    await chunkTransport.flush();
    expect(transport.sent, hasLength(1));
    await chunkTransport.close();
  });

  test('chunk transport batches tiny data with adaptive flush delay', () async {
    final temp = await Directory.systemTemp.createTemp('btun_small_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      chunkSize: 1024 * 1024,
    );
    final transport = _FakeTransport();
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: await BtunCrypto.fromConfig(
        config,
        send: Direction.c2r,
        receive: Direction.r2c,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: config.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: config.chunkSize,
      retryTimeout: const Duration(minutes: 1),
      maxInFlight: 1,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      interactiveFlushDelay: const Duration(milliseconds: 20),
      controlFlushDelay: const Duration(minutes: 1),
      ackDelay: const Duration(minutes: 1),
    );
    await chunkTransport.start();

    expect(transport.sent, isEmpty);
    for (var i = 0; i < 3; i++) {
      await chunkTransport.sendFrame(
        TunnelFrame.data(
          sessionId: config.sessionId,
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: i + 1,
          payload: [i],
        ),
      );
    }

    expect(transport.sent, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(transport.sent, hasLength(1));
    final relayCrypto = await BtunCrypto.fromConfig(
      BtunConfig.defaults(profileDir: temp.path).copyWith(
        sessionId: 'testsession',
        localPublicKey: relayKeys.publicKey,
        localPrivateKey: relayKeys.privateKey,
        peerPublicKey: clientKeys.publicKey,
      ),
      send: Direction.r2c,
      receive: Direction.c2r,
    );
    final sent = EncryptedChunkFile.decode(transport.sent.single.bytes);
    final plain = await relayCrypto.decrypt(sent);
    expect(plain.frames, hasLength(3));
    await chunkTransport.close();
  });

  test(
    'chunk transport flushes interactive burst below regular chunk size',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'btun_interactive_burst_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final clientKeys = await BtunCrypto.generateKeyPair();
      final relayKeys = await BtunCrypto.generateKeyPair();
      final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
        sessionId: 'testsession',
        localPublicKey: clientKeys.publicKey,
        localPrivateKey: clientKeys.privateKey,
        peerPublicKey: relayKeys.publicKey,
        chunkSize: 1024 * 1024,
      );
      final transport = _FakeTransport();
      final chunkTransport = ChunkTransport(
        transport: transport,
        crypto: await BtunCrypto.fromConfig(
          config,
          send: Direction.c2r,
          receive: Direction.r2c,
        ),
        stateDb: StateDb.open('${temp.path}/state.json'),
        sessionId: config.sessionId,
        sendDirection: Direction.c2r,
        receiveDirection: Direction.r2c,
        chunkSize: config.chunkSize,
        retryTimeout: const Duration(minutes: 1),
        maxInFlight: 1,
        logger: const Logger(),
        flushDelay: const Duration(minutes: 1),
        interactiveChunkSize: 1400,
        interactiveFlushDelay: const Duration(minutes: 1),
        ackDelay: const Duration(minutes: 1),
      );
      await chunkTransport.start();

      await chunkTransport.sendFrame(
        TunnelFrame.data(
          sessionId: config.sessionId,
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: 1,
          payload: List<int>.filled(800, 1),
        ),
      );
      expect(transport.sent, isEmpty);
      await chunkTransport.sendFrame(
        TunnelFrame.data(
          sessionId: config.sessionId,
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: 2,
          payload: List<int>.filled(800, 2),
        ),
      );

      expect(transport.sent, hasLength(1));
      await chunkTransport.close();
    },
  );

  test(
    'chunk transport flushes ack immediately when ack delay is zero',
    () async {
      final temp = await Directory.systemTemp.createTemp('btun_ack_zero_test_');
      addTearDown(() => temp.delete(recursive: true));
      final clientKeys = await BtunCrypto.generateKeyPair();
      final relayKeys = await BtunCrypto.generateKeyPair();
      final clientConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
        sessionId: 'testsession',
        localPublicKey: clientKeys.publicKey,
        localPrivateKey: clientKeys.privateKey,
        peerPublicKey: relayKeys.publicKey,
        chunkSize: 1024 * 1024,
      );
      final relayConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
        sessionId: 'testsession',
        localPublicKey: relayKeys.publicKey,
        localPrivateKey: relayKeys.privateKey,
        peerPublicKey: clientKeys.publicKey,
      );
      final transport = _FakeTransport();
      final chunkTransport = ChunkTransport(
        transport: transport,
        crypto: await BtunCrypto.fromConfig(
          clientConfig,
          send: Direction.c2r,
          receive: Direction.r2c,
        ),
        stateDb: StateDb.open('${temp.path}/state.json'),
        sessionId: clientConfig.sessionId,
        sendDirection: Direction.c2r,
        receiveDirection: Direction.r2c,
        chunkSize: clientConfig.chunkSize,
        retryTimeout: const Duration(minutes: 1),
        maxInFlight: 1,
        logger: const Logger(),
        flushDelay: const Duration(minutes: 1),
        ackDelay: Duration.zero,
      );
      await chunkTransport.start();

      final relayCrypto = await BtunCrypto.fromConfig(
        relayConfig,
        send: Direction.r2c,
        receive: Direction.c2r,
      );
      final incoming = await relayCrypto.encrypt(
        PlainChunk(
          version: 1,
          sessionId: clientConfig.sessionId,
          direction: Direction.r2c,
          sequenceNumber: 7,
          frames: [
            TunnelFrame.data(
              sessionId: clientConfig.sessionId,
              direction: Direction.r2c,
              streamId: 1,
              sequenceNumber: 1,
              payload: [1],
            ),
          ],
        ),
      );
      transport.addIncoming(
        IncomingTunnelFile(
          messageId: 'remote-7',
          fileName: btunFileName(clientConfig.sessionId, Direction.r2c, 7),
          bytes: incoming.encode(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(transport.sent, hasLength(1));
      final sent = EncryptedChunkFile.decode(transport.sent.single.bytes);
      final plain = await relayCrypto.decrypt(sent);
      expect(plain.frames.single.type, FrameType.ack);
      await chunkTransport.close();
    },
  );

  test('chunk transport batches open data and close in one file', () async {
    final temp = await Directory.systemTemp.createTemp('btun_burst_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final clientConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      chunkSize: 1024 * 1024,
    );
    final relayConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: relayKeys.publicKey,
      localPrivateKey: relayKeys.privateKey,
      peerPublicKey: clientKeys.publicKey,
    );
    final transport = _FakeTransport();
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: await BtunCrypto.fromConfig(
        clientConfig,
        send: Direction.c2r,
        receive: Direction.r2c,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: clientConfig.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: clientConfig.chunkSize,
      retryTimeout: const Duration(minutes: 1),
      maxInFlight: 1,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      controlFlushDelay: const Duration(milliseconds: 10),
      ackDelay: const Duration(minutes: 1),
    );
    await chunkTransport.start();

    await chunkTransport.sendFrames([
      TunnelFrame.open(
        sessionId: clientConfig.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        host: 'example.com',
        port: 443,
      ),
      TunnelFrame.data(
        sessionId: clientConfig.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 2,
        payload: [1, 2, 3],
      ),
      TunnelFrame.close(
        sessionId: clientConfig.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 3,
      ),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(transport.sent, hasLength(1));

    await chunkTransport.flush();

    expect(transport.sent, hasLength(1));
    final relayCrypto = await BtunCrypto.fromConfig(
      relayConfig,
      send: Direction.r2c,
      receive: Direction.c2r,
    );
    final sent = EncryptedChunkFile.decode(transport.sent.single.bytes);
    final plain = await relayCrypto.decrypt(sent);
    expect(plain.frames.map((frame) => frame.type), [
      FrameType.open,
      FrameType.data,
      FrameType.close,
    ]);
    await chunkTransport.close();
  });

  test(
    'chunk transport flushes immediately when queued bytes hit chunk size',
    () async {
      final temp = await Directory.systemTemp.createTemp('btun_size_test_');
      addTearDown(() => temp.delete(recursive: true));
      final clientKeys = await BtunCrypto.generateKeyPair();
      final relayKeys = await BtunCrypto.generateKeyPair();
      final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
        sessionId: 'testsession',
        localPublicKey: clientKeys.publicKey,
        localPrivateKey: clientKeys.privateKey,
        peerPublicKey: relayKeys.publicKey,
        chunkSize: 260,
      );
      final transport = _FakeTransport();
      final chunkTransport = ChunkTransport(
        transport: transport,
        crypto: await BtunCrypto.fromConfig(
          config,
          send: Direction.c2r,
          receive: Direction.r2c,
        ),
        stateDb: StateDb.open('${temp.path}/state.json'),
        sessionId: config.sessionId,
        sendDirection: Direction.c2r,
        receiveDirection: Direction.r2c,
        chunkSize: config.chunkSize,
        retryTimeout: const Duration(minutes: 1),
        maxInFlight: 1,
        logger: const Logger(),
        flushDelay: const Duration(minutes: 1),
      );
      await chunkTransport.start();

      await chunkTransport.sendFrame(
        TunnelFrame.data(
          sessionId: config.sessionId,
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: 1,
          payload: [1, 2, 3, 4],
        ),
      );

      expect(transport.sent, hasLength(1));
      await chunkTransport.close();
    },
  );

  test('chunk transport promotes sustained data to bulk chunks', () async {
    final temp = await Directory.systemTemp.createTemp('btun_bulk_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      chunkSize: 700,
      bulkChunkSize: 2048,
    );
    final transport = _FakeTransport();
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: await BtunCrypto.fromConfig(
        config,
        send: Direction.c2r,
        receive: Direction.r2c,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: config.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: config.chunkSize,
      bulkChunkSize: config.bulkChunkSize,
      retryTimeout: const Duration(minutes: 1),
      maxInFlight: 1,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      bulkFlushDelay: const Duration(minutes: 1),
    );
    await chunkTransport.start();

    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: List<int>.filled(400, 1),
      ),
    );
    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 2,
        payload: List<int>.filled(400, 2),
      ),
    );

    expect(transport.sent, isEmpty);
    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 3,
        payload: List<int>.filled(800, 3),
      ),
    );
    expect(transport.sent, hasLength(1));
    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 4,
        payload: List<int>.filled(800, 4),
      ),
    );
    expect(transport.sent, hasLength(1));
    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 5,
        payload: List<int>.filled(800, 5),
      ),
    );
    expect(transport.sent, hasLength(2));
    await chunkTransport.close();
  });

  test('chunk transport resets idle stream to interactive mode', () async {
    final temp = await Directory.systemTemp.createTemp('btun_idle_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      chunkSize: 10000,
    );
    final transport = _FakeTransport();
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: await BtunCrypto.fromConfig(
        config,
        send: Direction.c2r,
        receive: Direction.r2c,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: config.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: config.chunkSize,
      retryTimeout: const Duration(minutes: 1),
      maxInFlight: 1,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      interactiveChunkSize: 700,
      interactiveFrameLimit: 1,
      interactiveWindow: Duration.zero,
      streamIdleTimeout: const Duration(milliseconds: 30),
      ackDelay: const Duration(minutes: 1),
    );
    await chunkTransport.start();

    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: [1],
      ),
    );
    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 2,
        payload: [2],
      ),
    );
    expect(transport.sent, isEmpty);
    await chunkTransport.flush();
    expect(transport.sent, hasLength(1));

    await Future<void>.delayed(const Duration(milliseconds: 60));
    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 3,
        payload: List<int>.filled(800, 3),
      ),
    );

    expect(transport.sent, hasLength(2));
    await chunkTransport.close();
  });

  test('chunk transport retries unacked chunks from memory', () async {
    final temp = await Directory.systemTemp.createTemp('btun_retry_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      chunkSize: 1024 * 1024,
    );
    final transport = _FakeTransport();
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: await BtunCrypto.fromConfig(
        config,
        send: Direction.c2r,
        receive: Direction.r2c,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: config.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: config.chunkSize,
      retryTimeout: Duration.zero,
      maxInFlight: 1,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      retryTick: const Duration(milliseconds: 20),
    );
    await chunkTransport.start();

    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: [1, 2, 3],
      ),
    );
    await chunkTransport.flush();
    expect(transport.sent, hasLength(1));
    final first = transport.sent.single;

    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(transport.sent.length, greaterThan(1));
    expect(transport.sent.last.sequenceNumber, first.sequenceNumber);
    expect(transport.sent.last.bytes, first.bytes);
    await chunkTransport.close();
  });

  test('chunk transport pauses retries during account cooldown', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_retry_cooldown_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      chunkSize: 1024 * 1024,
    );
    final transport = _FakeTransport();
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: await BtunCrypto.fromConfig(
        config,
        send: Direction.c2r,
        receive: Direction.r2c,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: config.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: config.chunkSize,
      retryTimeout: Duration.zero,
      maxInFlight: 1,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      retryTick: const Duration(milliseconds: 20),
    );
    await chunkTransport.start();

    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: [1, 2, 3],
      ),
    );
    await chunkTransport.flush();
    transport.temporaryFailure = BtunAccountTemporarilyUnavailable(
      operation: 'send btun_testsession_c2r_1.btun',
      reason: 'all accounts are cooling down',
      retryAfter: DateTime.now().add(const Duration(seconds: 2)),
    );

    await Future<void>.delayed(const Duration(milliseconds: 90));

    expect(transport.sent, hasLength(2));
    await chunkTransport.close();
  });

  test('chunk transport removes memory retry records after ack', () async {
    final temp = await Directory.systemTemp.createTemp('btun_ack_retry_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final clientConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      chunkSize: 1024 * 1024,
    );
    final relayConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: relayKeys.publicKey,
      localPrivateKey: relayKeys.privateKey,
      peerPublicKey: clientKeys.publicKey,
    );
    final transport = _FakeTransport();
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: await BtunCrypto.fromConfig(
        clientConfig,
        send: Direction.c2r,
        receive: Direction.r2c,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: clientConfig.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: clientConfig.chunkSize,
      retryTimeout: Duration.zero,
      maxInFlight: 1,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      retryTick: const Duration(milliseconds: 20),
    );
    await chunkTransport.start();

    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: clientConfig.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: [1],
      ),
    );
    await chunkTransport.flush();
    final sentSequence = transport.sent.single.sequenceNumber;

    final relayCrypto = await BtunCrypto.fromConfig(
      relayConfig,
      send: Direction.r2c,
      receive: Direction.c2r,
    );
    final incoming = await relayCrypto.encrypt(
      PlainChunk(
        version: 1,
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        sequenceNumber: 1,
        frames: [
          TunnelFrame.ack(
            sessionId: clientConfig.sessionId,
            direction: Direction.r2c,
            ackNumber: sentSequence,
          ),
        ],
      ),
    );
    transport.addIncoming(
      IncomingTunnelFile(
        messageId: 'remote-ack',
        fileName: btunFileName(clientConfig.sessionId, Direction.r2c, 1),
        bytes: incoming.encode(),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(transport.sent, hasLength(1));
    await chunkTransport.close();
  });

  test('chunk transport treats ack numbers as exact chunk receipts', () async {
    final temp = await Directory.systemTemp.createTemp('btun_exact_ack_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final clientConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      chunkSize: 1024 * 1024,
    );
    final relayConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: relayKeys.publicKey,
      localPrivateKey: relayKeys.privateKey,
      peerPublicKey: clientKeys.publicKey,
    );
    final transport = _FakeTransport();
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: await BtunCrypto.fromConfig(
        clientConfig,
        send: Direction.c2r,
        receive: Direction.r2c,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: clientConfig.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: clientConfig.chunkSize,
      retryTimeout: Duration.zero,
      maxInFlight: 10,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      retryTick: const Duration(milliseconds: 20),
    );
    await chunkTransport.start();

    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: clientConfig.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: [1],
      ),
    );
    await chunkTransport.flush();
    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: clientConfig.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 2,
        payload: [2],
      ),
    );
    await chunkTransport.flush();
    final firstSequence = transport.sent[0].sequenceNumber;
    final secondSequence = transport.sent[1].sequenceNumber;

    final relayCrypto = await BtunCrypto.fromConfig(
      relayConfig,
      send: Direction.r2c,
      receive: Direction.c2r,
    );
    final incoming = await relayCrypto.encrypt(
      PlainChunk(
        version: 1,
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        sequenceNumber: 1,
        frames: [
          TunnelFrame.ack(
            sessionId: clientConfig.sessionId,
            direction: Direction.r2c,
            ackNumber: secondSequence,
          ),
        ],
      ),
    );
    transport.addIncoming(
      IncomingTunnelFile(
        messageId: 'remote-ack',
        fileName: btunFileName(clientConfig.sessionId, Direction.r2c, 1),
        bytes: incoming.encode(),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(
      transport.sent
          .skip(2)
          .map((file) => file.sequenceNumber)
          .contains(firstSequence),
      isTrue,
    );
    expect(
      transport.sent
          .skip(2)
          .map((file) => file.sequenceNumber)
          .contains(secondSequence),
      isFalse,
    );
    await chunkTransport.close();
  });

  test('chunk transport piggybacks pending ack onto outgoing data', () async {
    final temp = await Directory.systemTemp.createTemp('btun_ack_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final clientConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      chunkSize: 1024 * 1024,
    );
    final relayConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: relayKeys.publicKey,
      localPrivateKey: relayKeys.privateKey,
      peerPublicKey: clientKeys.publicKey,
    );
    final transport = _FakeTransport();
    final clientCrypto = await BtunCrypto.fromConfig(
      clientConfig,
      send: Direction.c2r,
      receive: Direction.r2c,
    );
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: clientCrypto,
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: clientConfig.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: clientConfig.chunkSize,
      retryTimeout: const Duration(minutes: 1),
      maxInFlight: 1,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      controlFlushDelay: const Duration(minutes: 1),
      ackDelay: const Duration(milliseconds: 200),
    );
    await chunkTransport.start();

    final relayCrypto = await BtunCrypto.fromConfig(
      relayConfig,
      send: Direction.r2c,
      receive: Direction.c2r,
    );
    final incoming = await relayCrypto.encrypt(
      PlainChunk(
        version: 1,
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        sequenceNumber: 7,
        frames: [
          TunnelFrame.data(
            sessionId: clientConfig.sessionId,
            direction: Direction.r2c,
            streamId: 1,
            sequenceNumber: 1,
            payload: [1],
          ),
        ],
      ),
    );
    transport.addIncoming(
      IncomingTunnelFile(
        messageId: 'remote-7',
        fileName: btunFileName(clientConfig.sessionId, Direction.r2c, 7),
        bytes: incoming.encode(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(transport.sent, isEmpty);

    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: clientConfig.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 2,
        payload: [2],
      ),
    );
    await chunkTransport.flush();

    expect(transport.sent, hasLength(1));
    final sent = EncryptedChunkFile.decode(transport.sent.single.bytes);
    final plain = await relayCrypto.decrypt(sent);
    expect(plain.frames.map((frame) => frame.type), contains(FrameType.ack));
    await chunkTransport.close();
  });

  test('rate limit detection recognizes Bale code 8', () {
    expect(
      isBaleRateLimit(const BaleException('user_rate_limited', code: 8)),
      isTrue,
    );
    expect(isBaleRateLimit(Exception('user_rate_limited (code 8)')), isTrue);
    expect(isBaleRateLimit(const BaleException('other', code: 1)), isFalse);
  });

  test('transient Bale HTTP errors are detected', () {
    expect(
      isBaleTransientHttpError(Exception('Upload failed with HTTP 500: ')),
      isTrue,
    );
    expect(
      isBaleTransientHttpError(Exception('Download failed with HTTP 503')),
      isTrue,
    );
    expect(
      isBaleTransientHttpError(Exception('Download failed with HTTP 404')),
      isFalse,
    );
  });

  test(
    'saved messages upload pacing is serialized across concurrency',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'btun_upload_pace_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final client = _FakeBaleClient();
      final transport = BaleSavedMessagesTransport(
        client: client,
        sessionId: 'testsession',
        sendDirection: Direction.c2r,
        receiveDirection: Direction.r2c,
        pollInterval: const Duration(days: 1),
        maxPollInterval: const Duration(days: 2),
        stateDb: StateDb.open('${temp.path}/state.json'),
        uploadMinInterval: const Duration(milliseconds: 30),
        uploadRateLimitPerMinute: 50,
        logger: const Logger(),
        maxConcurrentUploads: 3,
      );

      await Future.wait([
        transport.sendFile(
          const OutgoingTunnelFile(
            fileName: 'btun_testsession_c2r_1.btun',
            bytes: [1],
            sequenceNumber: 1,
            direction: Direction.c2r,
          ),
        ),
        transport.sendFile(
          const OutgoingTunnelFile(
            fileName: 'btun_testsession_c2r_2.btun',
            bytes: [2],
            sequenceNumber: 2,
            direction: Direction.c2r,
          ),
        ),
        transport.sendFile(
          const OutgoingTunnelFile(
            fileName: 'btun_testsession_c2r_3.btun',
            bytes: [3],
            sequenceNumber: 3,
            direction: Direction.c2r,
          ),
        ),
      ]);

      expect(client.sentAt, hasLength(3));
      expect(
        client.sentAt[1].difference(client.sentAt[0]).inMilliseconds,
        greaterThanOrEqualTo(20),
      );
      expect(
        client.sentAt[2].difference(client.sentAt[1]).inMilliseconds,
        greaterThanOrEqualTo(20),
      );
      await transport.close();
    },
  );

  test('saved messages upload rate limit fails fast for failover', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_upload_failover_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final client = _FakeBaleClient(
      sendError: const BaleException('user_rate_limited', code: 8),
    );
    final transport = BaleSavedMessagesTransport(
      client: client,
      sessionId: 'testsession',
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      pollInterval: const Duration(days: 1),
      maxPollInterval: const Duration(days: 2),
      stateDb: StateDb.open('${temp.path}/state.json'),
      uploadMinInterval: Duration.zero,
      uploadRateLimitPerMinute: 50,
      logger: const Logger(),
      maxConcurrentUploads: 1,
      accountUserId: 42,
    );

    await expectLater(
      transport.sendFile(
        const OutgoingTunnelFile(
          fileName: 'btun_testsession_c2r_1.btun',
          bytes: [1],
          sequenceNumber: 1,
          direction: Direction.c2r,
        ),
      ),
      throwsA(
        isA<BtunAccountTemporarilyUnavailable>()
            .having((error) => error.accountUserId, 'accountUserId', 42)
            .having((error) => error.reason, 'reason', 'rate limited'),
      ),
    );

    expect(transport.isBackingOff, isTrue);
    expect(transport.backoffUntil, isNotNull);
    await transport.close();
  });

  test('saved messages upload stable pacing uses configured ceiling', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_upload_warm_start_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final client = _FakeBaleClient();
    final transport = BaleSavedMessagesTransport(
      client: client,
      sessionId: 'testsession',
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      pollInterval: const Duration(days: 1),
      maxPollInterval: const Duration(days: 2),
      stateDb: StateDb.open('${temp.path}/state.json'),
      uploadMinInterval: Duration.zero,
      uploadRateLimitPerMinute: 50,
      logger: const Logger(),
      maxConcurrentUploads: 50,
    );

    await Future.wait([
      for (var i = 1; i <= 50; i += 1)
        transport.sendFile(
          OutgoingTunnelFile(
            fileName: 'btun_testsession_c2r_$i.btun',
            bytes: [i],
            sequenceNumber: i,
            direction: Direction.c2r,
          ),
        ),
    ]);

    expect(client.sentAt, hasLength(50));
    await transport.close();
  });

  test('saved messages transport does not poll immediately on start', () async {
    final temp = await Directory.systemTemp.createTemp('btun_idle_poll_test_');
    addTearDown(() => temp.delete(recursive: true));
    final client = _FakeBaleClient();
    final transport = BaleSavedMessagesTransport(
      client: client,
      sessionId: 'testsession',
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      pollInterval: const Duration(milliseconds: 80),
      maxPollInterval: const Duration(milliseconds: 400),
      stateDb: StateDb.open('${temp.path}/state.json'),
      uploadMinInterval: Duration.zero,
      uploadRateLimitPerMinute: 50,
      logger: const Logger(),
      maxConcurrentUploads: 1,
      accountUserId: 42,
    );

    await transport.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(client.loadHistoryCalls, isZero);
    await transport.close();
  });

  test('saved messages poll backs off without rapid recovery', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_poll_backoff_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final client = _FakeBaleClient(
      loadHistoryErrors: [const BaleException('user_rate_limited', code: 8)],
    );
    final transport = BaleSavedMessagesTransport(
      client: client,
      sessionId: 'testsession',
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      pollInterval: const Duration(milliseconds: 10),
      maxPollInterval: const Duration(milliseconds: 40),
      stateDb: StateDb.open('${temp.path}/state.json'),
      uploadMinInterval: Duration.zero,
      uploadRateLimitPerMinute: 50,
      logger: const Logger(),
      maxConcurrentUploads: 1,
      accountUserId: 42,
    );

    await transport.start();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(client.loadHistoryCalls, 1);
    expect(transport.pollInterval, const Duration(milliseconds: 10));
    await transport.close();
  });

  test('btun client enforces max stream slots', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_stream_slots_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
      maxStreams: 1,
    );
    final transport = _FakeTransport();
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: await BtunCrypto.fromConfig(
        config,
        send: Direction.c2r,
        receive: Direction.r2c,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: config.sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: config.chunkSize,
      retryTimeout: config.retryTimeout,
      maxInFlight: config.maxInFlight,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      ackDelay: const Duration(minutes: 1),
    );
    final client = BtunClient(config: config, chunkTransport: chunkTransport);

    final first = await client.open('example.com', 443);
    await expectLater(
      client.open(
        'example.org',
        443,
        slotTimeout: const Duration(milliseconds: 30),
      ),
      throwsA(isA<TimeoutException>()),
    );

    await first.close();
    final second = await client.open(
      'example.org',
      443,
      slotTimeout: const Duration(milliseconds: 100),
    );

    await second.close();
    await client.close();
    await chunkTransport.close();
  });

  test('config fills missing transport settings with adaptive defaults', () {
    final config = BtunConfig.fromJson({
      'role': 'client',
      'session_file': 'session.json',
      'database': 'state.json',
      'session_id': 'testsession',
      'local_public_key': '',
      'local_private_key': '',
    });

    expect(config.adaptive, BtunAdaptiveConfig.defaults);
    expect(config.chunkSize, 1024 * 1024);
    expect(config.maxInFlight, 1);
    expect(config.pollInterval, const Duration(milliseconds: 2000));
    expect(config.maxPollInterval, const Duration(milliseconds: 2000));
    expect(config.uploadMinInterval, Duration.zero);
    expect(config.uploadRateLimitPerMinute, 50);
    expect(config.ackFlushInterval, const Duration(milliseconds: 600));
    expect(config.flushDelay, const Duration(milliseconds: 150));
    expect(config.bulkFlushDelay, const Duration(milliseconds: 1000));
    expect(config.bulkChunkSize, 2 * 1024 * 1024);
    expect(config.maxRetryChunks, 64);
    expect(config.maxRetryBytes, 64 * 1024 * 1024);
  });

  test('config clamps unsafe adaptive values to stable bounds', () {
    final config = BtunConfig.fromJson({
      'role': 'client',
      'session_file': 'session.json',
      'database': 'state.json',
      'session_id': 'testsession',
      'local_public_key': '',
      'local_private_key': '',
      'adaptive': {
        'min_poll_interval_ms': 300,
        'max_poll_interval_ms': 300,
        'min_ack_flush_interval_ms': 100,
        'max_ack_flush_interval_ms': 100,
        'min_flush_delay_ms': 50,
        'max_flush_delay_ms': 250,
        'min_upload_rate_per_minute': 10,
        'max_upload_rate_per_minute': 25,
        'min_chunk_size': 64 * 1024,
        'max_chunk_size': 1024 * 1024,
        'max_in_flight': 1,
        'max_streams': 4,
      },
    });

    expect(config.chunkSize, 1024 * 1024);
    expect(config.bulkChunkSize, 2 * 1024 * 1024);
    expect(config.pollInterval, const Duration(milliseconds: 2000));
    expect(config.maxPollInterval, const Duration(milliseconds: 2000));
    expect(config.adaptive.minUploadRatePerMinute, 40);
    expect(config.uploadRateLimitPerMinute, 50);
    expect(config.ackFlushInterval, const Duration(milliseconds: 600));
    expect(config.maxAckFlushInterval, const Duration(milliseconds: 800));
    expect(config.flushDelay, const Duration(milliseconds: 150));
    expect(config.bulkFlushDelay, const Duration(milliseconds: 1000));
  });

  test('config ignores old fixed upload rate fields', () {
    final config = BtunConfig.fromJson({
      'role': 'client',
      'session_file': 'session.json',
      'database': 'state.json',
      'session_id': 'testsession',
      'local_public_key': '',
      'local_private_key': '',
      'upload_rate_limit_per_minute': 40,
    });

    expect(config.uploadRateLimitPerMinute, 50);
  });

  test('config defaults use balanced interactive bounds', () {
    final config = BtunConfig.defaults(profileDir: '.btun-test');

    expect(config.adaptive, BtunAdaptiveConfig.defaults);
    expect(config.chunkSize, 1024 * 1024);
    expect(config.maxInFlight, 1);
    expect(config.pollInterval, const Duration(milliseconds: 2000));
    expect(config.maxPollInterval, const Duration(milliseconds: 2000));
    expect(config.uploadMinInterval, Duration.zero);
    expect(config.uploadRateLimitPerMinute, 50);
    expect(config.ackFlushInterval, const Duration(milliseconds: 600));
    expect(config.flushDelay, const Duration(milliseconds: 150));
    expect(config.bulkFlushDelay, const Duration(milliseconds: 1000));
    expect(config.bulkChunkSize, 2 * 1024 * 1024);
    expect(config.maxRetryChunks, 64);
    expect(config.maxRetryBytes, 64 * 1024 * 1024);
  });
}

class _FakeBaleClient extends BaleClient {
  _FakeBaleClient({this.sendError, List<Object> loadHistoryErrors = const []})
    : _loadHistoryErrors = List<Object>.of(loadHistoryErrors);

  final sentAt = <DateTime>[];
  final _updates = StreamController<BaleUpdate>.broadcast();
  final Object? sendError;
  final List<Object> _loadHistoryErrors;
  var loadHistoryCalls = 0;

  @override
  BaleSession? get session =>
      const BaleSession(accessToken: 'test', userId: 42);

  @override
  Stream<BaleUpdate> get updates => _updates.stream;

  @override
  Future<List<BaleMessage>> loadHistory({
    required BalePeer peer,
    int limit = 20,
    int offsetDate = 9223372036854775807,
    int loadMode = 2,
  }) async {
    loadHistoryCalls += 1;
    if (_loadHistoryErrors.isNotEmpty) throw _loadHistoryErrors.removeAt(0);
    return const [];
  }

  @override
  Future<BaleMessage> sendDocument({
    required BalePeer peer,
    required BaleFileInput file,
    String? caption,
    int? messageId,
    void Function(int sent, int total)? onProgress,
  }) async {
    sentAt.add(DateTime.now());
    final error = sendError;
    if (error != null) throw error;
    return BaleMessage(
      chat: peer,
      senderId: session!.userId!,
      messageId: messageId ?? sentAt.length,
      date: sentAt.length,
    );
  }
}

class _FakeTransport implements TunnelTransport {
  final sent = <OutgoingTunnelFile>[];
  final _incoming = StreamController<IncomingTunnelFile>.broadcast();
  Object? temporaryFailure;

  @override
  bool get isBackingOff => false;

  @override
  DateTime? get backoffUntil => null;

  @override
  Future<void> close() async {
    await _incoming.close();
  }

  @override
  Stream<IncomingTunnelFile> incomingFiles() => _incoming.stream;

  @override
  Future<void> sendFile(OutgoingTunnelFile file) async {
    sent.add(file);
    final failure = temporaryFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> start() async {}

  void addIncoming(IncomingTunnelFile file) {
    _incoming.add(file);
  }
}
