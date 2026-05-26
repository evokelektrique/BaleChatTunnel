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
        transferMode: BtunTransferMode.balanced,
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
          version: 4,
          sessionId: clientConfig.sessionId,
          direction: Direction.r2c,
          sequenceNumber: 7,
          chunkEpoch: 'remote-test-epoch',
          reliableSequenceNumber: 7,
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
    'frame sequence allocation does not skip chunk sequence numbers',
    () async {
      final harness = await _ChunkHarness.create('btun_sequence_space_test_');
      addTearDown(harness.dispose);

      await harness.chunkTransport.sendFrame(
        TunnelFrame.open(
          sessionId: harness.clientConfig.sessionId,
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: harness.chunkTransport.allocateSequence(),
          host: 'example.com',
          port: 443,
        ),
      );
      await harness.chunkTransport.flush();
      await harness.chunkTransport.sendFrame(
        TunnelFrame.data(
          sessionId: harness.clientConfig.sessionId,
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: harness.chunkTransport.allocateSequence(),
          payload: [1],
        ),
      );
      await harness.chunkTransport.flush();
      await harness.chunkTransport.sendFrame(
        TunnelFrame.close(
          sessionId: harness.clientConfig.sessionId,
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: harness.chunkTransport.allocateSequence(),
        ),
      );
      await harness.chunkTransport.flush();

      expect(harness.transport.sent.map((file) => file.sequenceNumber), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'chunk transport flushes immediately when queued bytes hit chunk size',
    () async {
      final temp = await Directory.systemTemp.createTemp('btun_size_test_');
      addTearDown(() => temp.delete(recursive: true));
      final clientKeys = await BtunCrypto.generateKeyPair();
      final relayKeys = await BtunCrypto.generateKeyPair();
      final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
        transferMode: BtunTransferMode.balanced,
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
      transferMode: BtunTransferMode.balanced,
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

  test('bulk transfer mode waits for larger chunk target', () async {
    final temp = await Directory.systemTemp.createTemp('btun_bulk_mode_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
      transferMode: BtunTransferMode.bulk,
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
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
      retryTimeout: config.retryTimeout,
      maxInFlight: config.maxInFlight,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      bulkFlushDelay: const Duration(minutes: 1),
      interactiveChunkSize: config.interactiveChunkSize,
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
        payload: List<int>.filled(2 * 1024 * 1024, 1),
      ),
    );
    expect(transport.sent, isEmpty);

    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 2,
        payload: List<int>.filled(2 * 1024 * 1024, 2),
      ),
    );

    expect(transport.sent, hasLength(1));
    await chunkTransport.close();
  });

  test('bulk-style cadence flushes queued data on timer', () async {
    final temp = await Directory.systemTemp.createTemp('btun_bulk_timer_test_');
    addTearDown(() => temp.delete(recursive: true));
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final config = BtunConfig.defaults(profileDir: temp.path).copyWith(
      transferMode: BtunTransferMode.bulk,
      sessionId: 'testsession',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
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
      retryTimeout: config.retryTimeout,
      maxInFlight: config.maxInFlight,
      logger: const Logger(),
      flushDelay: const Duration(milliseconds: 30),
      bulkFlushDelay: const Duration(milliseconds: 30),
      interactiveChunkSize: config.interactiveChunkSize,
      interactiveFlushDelay: const Duration(milliseconds: 30),
      ackDelay: const Duration(minutes: 1),
    );
    await chunkTransport.start();

    await chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: config.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: List<int>.filled(1024 * 1024, 1),
      ),
    );

    expect(transport.sent, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(transport.sent, hasLength(1));
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
        version: 4,
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        sequenceNumber: 1,
        chunkEpoch: 'remote-test-epoch',
        reliableSequenceNumber: 0,
        ackOnly: true,
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

  test('chunk transport treats ack numbers as cumulative receipts', () async {
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
        version: 4,
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        sequenceNumber: 1,
        chunkEpoch: 'remote-test-epoch',
        reliableSequenceNumber: 0,
        ackOnly: true,
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
      isFalse,
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
        version: 4,
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        sequenceNumber: 1,
        chunkEpoch: 'remote-test-epoch',
        reliableSequenceNumber: 1,
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
        fileName: btunFileName(clientConfig.sessionId, Direction.r2c, 1),
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

  test('chunk transport delivers received chunks in sequence order', () async {
    final harness = await _ChunkHarness.create('btun_reorder_test_');
    addTearDown(harness.dispose);
    final received = <TunnelFrame>[];
    final sub = harness.chunkTransport.frames.listen(received.add);
    addTearDown(sub.cancel);

    await harness.addRemoteChunk(1, payload: [1]);
    await harness.addRemoteChunk(3, payload: [3]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(received.map((frame) => frame.payload.single), [1]);

    await harness.addRemoteChunk(2, payload: [2]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(received.map((frame) => frame.payload.single), [1, 2, 3]);
  });

  test('chunk transport anchors non-one first receive window', () async {
    final harness = await _ChunkHarness.create(
      'btun_reorder_baseline_test_',
      receiveBaselineDelay: const Duration(milliseconds: 20),
    );
    addTearDown(harness.dispose);
    final received = <TunnelFrame>[];
    final sub = harness.chunkTransport.frames.listen(received.add);
    addTearDown(sub.cancel);

    await harness.addRemoteChunk(9, payload: [9]);
    await harness.addRemoteChunk(10, payload: [10]);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(received.map((frame) => frame.payload.single), [9, 10]);
  });

  test(
    'chunk transport orders initial baseline window by lowest chunk',
    () async {
      final harness = await _ChunkHarness.create(
        'btun_reorder_baseline_order_test_',
        receiveBaselineDelay: const Duration(milliseconds: 20),
      );
      addTearDown(harness.dispose);
      final received = <TunnelFrame>[];
      final sub = harness.chunkTransport.frames.listen(received.add);
      addTearDown(sub.cancel);

      await harness.addRemoteChunk(11, payload: [11]);
      await harness.addRemoteChunk(9, payload: [9]);
      await harness.addRemoteChunk(10, payload: [10]);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(received.map((frame) => frame.payload.single), [9, 10, 11]);
    },
  );

  test(
    'chunk transport does not repeat identical ack for duplicates',
    () async {
      final harness = await _ChunkHarness.create(
        'btun_reorder_duplicate_test_',
        ackDelay: Duration.zero,
      );
      addTearDown(harness.dispose);
      final received = <TunnelFrame>[];
      final sub = harness.chunkTransport.frames.listen(received.add);
      addTearDown(sub.cancel);

      await harness.addRemoteChunk(1, payload: [1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await harness.addRemoteChunk(1, payload: [1]);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(received.map((frame) => frame.payload.single), [1]);
      expect(harness.transport.sent, hasLength(1));
    },
  );

  test('chunk transport updates ack when receive gap fills', () async {
    final harness = await _ChunkHarness.create(
      'btun_reorder_ack_gap_fill_test_',
      ackDelay: Duration.zero,
    );
    addTearDown(harness.dispose);

    await harness.addRemoteChunk(1, payload: [1]);
    await harness.addRemoteChunk(3, payload: [3]);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(harness.transport.sent, hasLength(2));

    await harness.addRemoteChunk(3, payload: [3]);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(harness.transport.sent, hasLength(2));

    await harness.addRemoteChunk(2, payload: [2]);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(harness.transport.sent, hasLength(3));

    final sent = EncryptedChunkFile.decode(harness.transport.sent.last.bytes);
    final plain = await harness.relayCrypto.decrypt(sent);
    final ack = plain.frames.lastWhere((frame) => frame.type == FrameType.ack);
    expect(ack.ackNumber, 3);
    expect(ack.sackRanges, isEmpty);
  });

  test('chunk transport ignores ack-only inbound for outbound ack', () async {
    final harness = await _ChunkHarness.create(
      'btun_ack_only_no_loop_test_',
      ackDelay: Duration.zero,
    );
    addTearDown(harness.dispose);

    await harness.chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: harness.clientConfig.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: [9],
      ),
    );
    await harness.chunkTransport.flush();
    expect(harness.transport.sent, hasLength(1));

    await harness.addRemoteAckOnly(1, ackNumber: 1);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(harness.transport.sent, hasLength(1));
  });

  test('v4 ack-only inbound does not block later reliable data', () async {
    final harness = await _ChunkHarness.create(
      'btun_v4_ack_only_gap_test_',
      ackDelay: Duration.zero,
    );
    addTearDown(harness.dispose);
    final received = <TunnelFrame>[];
    final sub = harness.chunkTransport.frames.listen(received.add);
    addTearDown(sub.cancel);

    await harness.addRemoteV4AckOnly(uploadSequence: 1, ackNumber: 0);
    await harness.addRemoteV4Chunk(
      uploadSequence: 2,
      reliableSequence: 1,
      payload: [7],
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(received.map((frame) => frame.payload.single), [7]);
  });

  test('v4 ack-only inbound does not establish receive baseline', () async {
    final harness = await _ChunkHarness.create(
      'btun_v4_ack_only_baseline_test_',
      ackDelay: Duration.zero,
    );
    addTearDown(harness.dispose);
    final received = <TunnelFrame>[];
    final sub = harness.chunkTransport.frames.listen(received.add);
    addTearDown(sub.cancel);

    await harness.addRemoteV4AckOnly(uploadSequence: 9, ackNumber: 0);
    await harness.addRemoteV4Chunk(
      uploadSequence: 10,
      reliableSequence: 2,
      payload: [2],
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(received, isEmpty);
    await harness.addRemoteV4Chunk(
      uploadSequence: 11,
      reliableSequence: 1,
      payload: [1],
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(received.map((frame) => frame.payload.single), [1, 2]);
  });

  test(
    'chunk transport catches files emitted during transport start',
    () async {
      final harness = await _ChunkHarness.create(
        'btun_start_race_test_',
        autoStart: false,
      );
      addTearDown(harness.dispose);
      final received = <TunnelFrame>[];
      final sub = harness.chunkTransport.frames.listen(received.add);
      addTearDown(sub.cancel);
      harness.transport.startIncoming = await harness.remoteFile(
        1,
        payload: [1],
      );

      await harness.chunkTransport.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received.map((frame) => frame.payload.single), [1]);
    },
  );

  test('chunk transport holds future chunks until the gap fills', () async {
    final harness = await _ChunkHarness.create('btun_reorder_gap_test_');
    addTearDown(harness.dispose);
    final received = <TunnelFrame>[];
    final sub = harness.chunkTransport.frames.listen(received.add);
    addTearDown(sub.cancel);

    await harness.addRemoteChunk(3, payload: [3]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(received, isEmpty);

    await harness.addRemoteChunk(1, payload: [1]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(received.map((frame) => frame.payload.single), [1]);

    await harness.addRemoteChunk(2, payload: [2]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(received.map((frame) => frame.payload.single), [1, 2, 3]);
  });

  test('chunk transport emits sack ranges for buffered chunks', () async {
    final harness = await _ChunkHarness.create(
      'btun_sack_test_',
      ackDelay: Duration.zero,
    );
    addTearDown(harness.dispose);

    await harness.addRemoteChunk(1, payload: [1]);
    await harness.addRemoteChunk(3, payload: [3]);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    final sent = EncryptedChunkFile.decode(harness.transport.sent.last.bytes);
    final plain = await harness.relayCrypto.decrypt(sent);
    final ack = plain.frames.lastWhere((frame) => frame.type == FrameType.ack);
    expect(ack.ackNumber, 1);
    expect(ack.sackRanges.map((range) => [range.start, range.end]), [
      [3, 3],
    ]);
  });

  test(
    'data after ack-only upload keeps contiguous reliable sequence',
    () async {
      final harness = await _ChunkHarness.create(
        'btun_v4_contiguous_reliable_test_',
        ackDelay: Duration.zero,
      );
      addTearDown(harness.dispose);

      await harness.chunkTransport.sendFrame(
        TunnelFrame.data(
          sessionId: harness.clientConfig.sessionId,
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: 1,
          payload: [1],
        ),
      );
      await harness.chunkTransport.flush();

      await harness.addRemoteV4Chunk(
        uploadSequence: 1,
        reliableSequence: 1,
        payload: [9],
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));

      await harness.chunkTransport.sendFrame(
        TunnelFrame.data(
          sessionId: harness.clientConfig.sessionId,
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: 2,
          payload: [2],
        ),
      );
      await harness.chunkTransport.flush();

      final plains = <PlainChunk>[];
      for (final file in harness.transport.sent) {
        plains.add(
          await harness.relayCrypto.decrypt(
            EncryptedChunkFile.decode(file.bytes),
          ),
        );
      }
      expect(plains.map((chunk) => chunk.sequenceNumber), [1, 2, 3]);
      expect(plains.map((chunk) => chunk.reliableSequenceNumber), [1, 0, 2]);
      expect(plains.map((chunk) => chunk.ackOnly), [false, true, false]);
    },
  );

  test('sack gap probes earliest missing reliable chunk', () async {
    final harness = await _ChunkHarness.create(
      'btun_sack_gap_probe_test_',
      ackDelay: Duration.zero,
      retryTimeout: const Duration(minutes: 1),
      retryTick: const Duration(minutes: 1),
    );
    addTearDown(harness.dispose);

    for (var i = 1; i <= 3; i += 1) {
      await harness.chunkTransport.sendFrame(
        TunnelFrame.data(
          sessionId: harness.clientConfig.sessionId,
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: i,
          payload: [i],
        ),
      );
      await harness.chunkTransport.flush();
    }
    expect(harness.transport.sent.map((file) => file.sequenceNumber), [
      1,
      2,
      3,
    ]);

    await harness.addRemoteV4AckOnly(
      uploadSequence: 1,
      ackNumber: 1,
      sackRanges: const [AckRange(start: 3, end: 3)],
    );
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(harness.transport.sent, hasLength(4));
    expect(harness.transport.sent.last.sequenceNumber, 2);
  });

  test('chunk transport processes ack frames in held chunks', () async {
    final harness = await _ChunkHarness.create(
      'btun_reorder_ack_test_',
      retryTimeout: Duration.zero,
      retryTick: const Duration(milliseconds: 20),
      receiveGapTimeout: const Duration(seconds: 1),
    );
    addTearDown(harness.dispose);

    await harness.addRemoteChunk(1, payload: [1]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await harness.chunkTransport.sendFrame(
      TunnelFrame.data(
        sessionId: harness.clientConfig.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: [9],
      ),
    );
    await harness.chunkTransport.flush();
    final ackedSequence = harness.transport.sent.single.sequenceNumber;

    await harness.addRemoteChunk(3, payload: [3], ackNumber: ackedSequence);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(harness.transport.sent, hasLength(2));
  });

  test(
    'chunk transport closes when established receive gap times out',
    () async {
      final harness = await _ChunkHarness.create(
        'btun_reorder_gap_timeout_test_',
        receiveGapTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(harness.dispose);
      final received = <TunnelFrame>[];
      final done = Completer<void>();
      final sub = harness.chunkTransport.frames.listen(
        received.add,
        onDone: done.complete,
      );
      addTearDown(sub.cancel);

      await harness.addRemoteChunk(1, payload: [1]);
      await harness.addRemoteChunk(3, payload: [3]);

      await done.future.timeout(const Duration(seconds: 1));
      expect(received.map((frame) => frame.payload.single), [1]);
    },
  );

  test(
    'closed chunk transport rejects future sends and writable waits',
    () async {
      final harness = await _ChunkHarness.create(
        'btun_closed_send_test_',
        receiveGapTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(harness.dispose);
      final done = Completer<void>();
      final sub = harness.chunkTransport.frames.listen(
        (_) {},
        onDone: done.complete,
      );
      addTearDown(sub.cancel);

      await harness.addRemoteChunk(1, payload: [1]);
      await harness.addRemoteChunk(3, payload: [3]);
      await done.future.timeout(const Duration(seconds: 1));

      final frame = TunnelFrame.data(
        sessionId: harness.clientConfig.sessionId,
        direction: Direction.c2r,
        streamId: 1,
        sequenceNumber: 1,
        payload: [9],
      );
      await expectLater(
        harness.chunkTransport.sendFrame(frame),
        throwsA(isA<ChunkTransportClosedException>()),
      );
      await expectLater(
        harness.chunkTransport.sendFrames([frame]),
        throwsA(isA<ChunkTransportClosedException>()),
      );
      await expectLater(
        harness.chunkTransport.waitUntilWritable(),
        throwsA(isA<ChunkTransportClosedException>()),
      );
    },
  );

  test('fatal receive gap does not flush ack for held chunk', () async {
    final harness = await _ChunkHarness.create(
      'btun_fatal_ack_test_',
      ackDelay: const Duration(minutes: 1),
      receiveGapTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(harness.dispose);
    final done = Completer<void>();
    final sub = harness.chunkTransport.frames.listen(
      (_) {},
      onDone: done.complete,
    );
    addTearDown(sub.cancel);

    await harness.addRemoteChunk(1, payload: [1]);
    await harness.addRemoteChunk(3, payload: [3]);
    await done.future.timeout(const Duration(seconds: 1));

    expect(harness.transport.sent, hasLength(1));
  });

  test(
    'timestamp-like first inbound chunk anchors after baseline grace',
    () async {
      final harness = await _ChunkHarness.create(
        'btun_timestamp_baseline_test_',
        receiveBaselineDelay: const Duration(milliseconds: 20),
      );
      addTearDown(harness.dispose);
      final received = <TunnelFrame>[];
      final sub = harness.chunkTransport.frames.listen(received.add);
      addTearDown(sub.cancel);
      final first = DateTime.now().millisecondsSinceEpoch;

      await harness.addRemoteChunk(first + 1, payload: [2]);
      await harness.addRemoteChunk(first, payload: [1]);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(received.map((frame) => frame.payload.single), [1, 2]);
    },
  );

  test('chunk transport closes on reorder buffer overflow', () async {
    final harness = await _ChunkHarness.create(
      'btun_reorder_overflow_test_',
      maxReorderChunks: 1,
    );
    addTearDown(harness.dispose);

    await harness.addRemoteChunk(3, payload: [3]);
    await harness.addRemoteChunk(4, payload: [4]);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    await expectLater(harness.chunkTransport.frames, emitsDone);
  });

  test('btun client fails active streams when chunk frames close', () async {
    final harness = await _ChunkHarness.create(
      'btun_client_transport_close_test_',
      receiveGapTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(harness.dispose);
    final client = BtunClient(
      config: harness.clientConfig,
      chunkTransport: harness.chunkTransport,
    );
    addTearDown(client.close);

    final stream = await client.open('example.com', 443);
    final incomingDone = Completer<void>();
    final sub = stream.incoming.listen(
      (_) {},
      onError: (_) {
        if (!incomingDone.isCompleted) incomingDone.complete();
      },
      onDone: () {
        if (!incomingDone.isCompleted) incomingDone.complete();
      },
    );
    addTearDown(sub.cancel);

    await harness.addRemoteChunk(1, payload: [1]);
    await harness.addRemoteChunk(3, payload: [3]);
    await incomingDone.future.timeout(const Duration(seconds: 1));

    await expectLater(
      client.open('example.org', 443, slotTimeout: const Duration(seconds: 1)),
      throwsA(isA<StateError>()),
    );
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

  test('saved messages reports uploaded tunnel file bytes', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_upload_traffic_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final deltas = <TunnelTrafficDelta>[];
    final transport = BaleSavedMessagesTransport(
      client: _FakeBaleClient(),
      sessionId: 'testsession',
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      pollInterval: const Duration(days: 1),
      maxPollInterval: const Duration(days: 2),
      stateDb: StateDb.open('${temp.path}/state.json'),
      uploadMinInterval: Duration.zero,
      uploadRateLimitPerMinute: 50,
      logger: const Logger(),
      onTraffic: deltas.add,
    );

    await transport.sendFile(
      const OutgoingTunnelFile(
        fileName: 'btun_testsession_c2r_1.btun',
        bytes: [1, 2, 3, 4],
        sequenceNumber: 1,
        direction: Direction.c2r,
      ),
    );

    expect(deltas.map((delta) => delta.uploadedBytes), [4]);
    expect(deltas.single.downloadedBytes, isZero);
    await transport.close();
  });

  test('saved messages reports downloaded tunnel file bytes', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_download_traffic_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final client = _FakeBaleClient(downloadBytes: [1, 2, 3, 4, 5]);
    final deltas = <TunnelTrafficDelta>[];
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
      onTraffic: deltas.add,
    );

    await transport.start();
    final incoming = expectLater(
      transport.incomingFiles(),
      emits(
        isA<IncomingTunnelFile>().having(
          (file) => file.bytes.length,
          'bytes.length',
          5,
        ),
      ),
    );
    client.addUpdate(
      const BaleMessageUpdate(
        BaleMessage(
          chat: BalePeer.private(42),
          senderId: 42,
          messageId: 7,
          date: 1,
          document: BaleFileDetails(
            fileId: 1,
            accessHash: 2,
            name: 'btun_testsession_r2c_00000001.bin',
            size: 5,
            mimeType: 'application/octet-stream',
          ),
        ),
      ),
    );

    await incoming;
    expect(deltas.map((delta) => delta.downloadedBytes), [5]);
    expect(deltas.single.uploadedBytes, isZero);
    await transport.close();
  });

  test('saved messages quarantines existing tunnel files on start', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_startup_quarantine_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    const stale = BaleMessage(
      chat: BalePeer.private(42),
      senderId: 42,
      messageId: 7,
      date: 1,
      document: BaleFileDetails(
        fileId: 1,
        accessHash: 2,
        name: 'btun_testsession_r2c_00000001.bin',
        size: 5,
        mimeType: 'application/octet-stream',
      ),
    );
    final client = _FakeBaleClient(
      downloadBytes: [1, 2, 3, 4, 5],
      loadHistoryMessages: const [stale],
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
    );
    final emitted = <IncomingTunnelFile>[];
    final sub = transport.incomingFiles().listen(emitted.add);
    addTearDown(sub.cancel);

    await transport.start();
    client.addUpdate(const BaleMessageUpdate(stale));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(client.loadHistoryCalls, 1);
    expect(client.downloadCalls, isZero);
    expect(emitted, isEmpty);
    await transport.close();
  });

  test('saved messages poll downloads unprocessed live history', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_poll_live_history_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    const live = BaleMessage(
      chat: BalePeer.private(42),
      senderId: 42,
      messageId: 8,
      date: 2,
      document: BaleFileDetails(
        fileId: 1,
        accessHash: 2,
        name: 'btun_testsession_r2c_00000002.bin',
        size: 3,
        mimeType: 'application/octet-stream',
      ),
    );
    final client = _FakeBaleClient(
      downloadBytes: [6, 7, 8],
      loadHistoryBatches: const [
        [],
        [live],
      ],
    );
    final transport = BaleSavedMessagesTransport(
      client: client,
      sessionId: 'testsession',
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      pollInterval: const Duration(milliseconds: 10),
      maxPollInterval: const Duration(milliseconds: 50),
      stateDb: StateDb.open('${temp.path}/state.json'),
      uploadMinInterval: Duration.zero,
      uploadRateLimitPerMinute: 50,
      logger: const Logger(),
    );

    await transport.start();
    await expectLater(
      transport.incomingFiles(),
      emits(
        isA<IncomingTunnelFile>().having((file) => file.bytes, 'bytes', [
          6,
          7,
          8,
        ]),
      ),
    );
    expect(client.loadHistoryCalls, greaterThanOrEqualTo(2));
    expect(client.downloadCalls, 1);
    await transport.close();
  });

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

  test('saved messages replaces pending ack-only uploads', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_ack_replace_test_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final client = _FakeBaleClient(blockFirstSend: true);
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
    );

    final active = transport.sendFile(
      const OutgoingTunnelFile(
        fileName: 'btun_testsession_c2r_1.btun',
        bytes: [1],
        sequenceNumber: 1,
        direction: Direction.c2r,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final firstAck = transport.sendFile(
      const OutgoingTunnelFile(
        fileName: 'btun_testsession_c2r_2.btun',
        bytes: [2],
        sequenceNumber: 2,
        direction: Direction.c2r,
        isAckOnly: true,
        replaceKey: 'ack',
      ),
    );
    final secondAck = transport.sendFile(
      const OutgoingTunnelFile(
        fileName: 'btun_testsession_c2r_3.btun',
        bytes: [3],
        sequenceNumber: 3,
        direction: Direction.c2r,
        isAckOnly: true,
        replaceKey: 'ack',
      ),
    );

    await expectLater(firstAck, throwsA(isA<BtunUploadSuperseded>()));
    client.releaseFirstSend();
    await active;
    await secondAck;

    expect(client.sentFileNames, [
      'btun_testsession_c2r_1.btun',
      'btun_testsession_c2r_3.btun',
    ]);
    await transport.close();
  });

  test(
    'saved messages sends queued data before stale ack-only uploads',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'btun_ack_priority_test_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final client = _FakeBaleClient(blockFirstSend: true);
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
      );

      final active = transport.sendFile(
        const OutgoingTunnelFile(
          fileName: 'btun_testsession_c2r_1.btun',
          bytes: [1],
          sequenceNumber: 1,
          direction: Direction.c2r,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final ack = transport.sendFile(
        const OutgoingTunnelFile(
          fileName: 'btun_testsession_c2r_2.btun',
          bytes: [2],
          sequenceNumber: 2,
          direction: Direction.c2r,
          isAckOnly: true,
          replaceKey: 'ack',
        ),
      );
      final data = transport.sendFile(
        const OutgoingTunnelFile(
          fileName: 'btun_testsession_c2r_3.btun',
          bytes: [3],
          sequenceNumber: 3,
          direction: Direction.c2r,
        ),
      );

      client.releaseFirstSend();
      await active;
      await data;
      await ack;

      expect(client.sentFileNames, [
        'btun_testsession_c2r_1.btun',
        'btun_testsession_c2r_3.btun',
        'btun_testsession_c2r_2.btun',
      ]);
      await transport.close();
    },
  );

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

    expect(client.loadHistoryCalls, 1);
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
      transferMode: BtunTransferMode.balanced,
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

  test('config fills missing transport settings with bulk defaults', () {
    final config = BtunConfig.fromJson({
      'role': 'client',
      'session_file': 'session.json',
      'database': 'state.json',
      'session_id': 'testsession',
      'local_public_key': '',
      'local_private_key': '',
    });

    expect(config.adaptive, BtunAdaptiveConfig.defaults);
    expect(config.transferMode, BtunTransferMode.bulk);
    expect(config.chunkSize, 4 * 1024 * 1024);
    expect(config.maxInFlight, 1);
    expect(config.pollInterval, const Duration(milliseconds: 2000));
    expect(config.maxPollInterval, const Duration(milliseconds: 2000));
    expect(config.uploadMinInterval, Duration.zero);
    expect(config.uploadRateLimitPerMinute, 30);
    expect(config.ackFlushInterval, const Duration(milliseconds: 800));
    expect(config.flushDelay, const Duration(seconds: 3));
    expect(config.bulkFlushDelay, const Duration(seconds: 3));
    expect(config.bulkChunkSize, 4 * 1024 * 1024);
    expect(config.maxRetryChunks, 64);
    expect(config.maxRetryBytes, 128 * 1024 * 1024);
  });

  test('config defaults to bulk transfer mode', () {
    final config = BtunConfig.defaults(profileDir: '.btun-test');

    expect(config.transferMode, BtunTransferMode.bulk);
    expect(config.chunkSize, 4 * 1024 * 1024);
    expect(config.bulkChunkSize, 4 * 1024 * 1024);
    expect(config.flushDelay, const Duration(seconds: 3));
    expect(config.uploadRateLimitPerMinute, 30);
    expect(config.interactiveChunkSize, 4 * 1024 * 1024);
  });

  test('bulk transfer mode applies large cadence preset', () {
    final config = BtunConfig.fromJson({
      'role': 'client',
      'database': 'state.json',
      'session_id': 'testsession',
      'local_public_key': '',
      'local_private_key': '',
      'transfer_mode': 'bulk',
    });

    expect(config.transferMode, BtunTransferMode.bulk);
    expect(config.chunkSize, 4 * 1024 * 1024);
    expect(config.bulkChunkSize, 4 * 1024 * 1024);
    expect(config.flushDelay, const Duration(seconds: 3));
    expect(config.bulkFlushDelay, const Duration(seconds: 3));
    expect(config.ackFlushInterval, const Duration(milliseconds: 800));
    expect(config.maxAckFlushInterval, const Duration(milliseconds: 1500));
    expect(config.uploadRateLimitPerMinute, 30);
    expect(config.maxRetryBytes, 128 * 1024 * 1024);
    expect(config.interactiveChunkSize, 4 * 1024 * 1024);
  });

  test('transfer mode round trips through config json', () {
    final config = BtunConfig.defaults(
      profileDir: '.btun-test',
    ).copyWith(transferMode: BtunTransferMode.bulk);
    final decoded = BtunConfig.fromJson(config.toJson());

    expect(decoded.transferMode, BtunTransferMode.bulk);
    expect(decoded.chunkSize, 4 * 1024 * 1024);
    expect(decoded.maxRetryBytes, 128 * 1024 * 1024);
  });

  test('config clamps unsafe adaptive values to stable bounds', () {
    final config = BtunConfig.fromJson({
      'role': 'client',
      'session_file': 'session.json',
      'database': 'state.json',
      'session_id': 'testsession',
      'local_public_key': '',
      'local_private_key': '',
      'transfer_mode': 'balanced',
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

    expect(config.uploadRateLimitPerMinute, 30);
  });

  test('config defaults use bulk bounds', () {
    final config = BtunConfig.defaults(profileDir: '.btun-test');

    expect(config.adaptive, BtunAdaptiveConfig.defaults);
    expect(config.transferMode, BtunTransferMode.bulk);
    expect(config.chunkSize, 4 * 1024 * 1024);
    expect(config.maxInFlight, 1);
    expect(config.pollInterval, const Duration(milliseconds: 2000));
    expect(config.maxPollInterval, const Duration(milliseconds: 2000));
    expect(config.uploadMinInterval, Duration.zero);
    expect(config.uploadRateLimitPerMinute, 30);
    expect(config.ackFlushInterval, const Duration(milliseconds: 800));
    expect(config.flushDelay, const Duration(seconds: 3));
    expect(config.bulkFlushDelay, const Duration(seconds: 3));
    expect(config.bulkChunkSize, 4 * 1024 * 1024);
    expect(config.maxRetryChunks, 64);
    expect(config.maxRetryBytes, 128 * 1024 * 1024);
  });
}

class _FakeBaleClient extends BaleClient {
  _FakeBaleClient({
    this.sendError,
    this.downloadBytes = const [],
    this.loadHistoryMessages = const [],
    List<List<BaleMessage>> loadHistoryBatches = const [],
    List<Object> loadHistoryErrors = const [],
    bool blockFirstSend = false,
  }) : _loadHistoryErrors = List<Object>.of(loadHistoryErrors),
       _loadHistoryBatches = [
         for (final batch in loadHistoryBatches) List<BaleMessage>.of(batch),
       ],
       _firstSendGate = blockFirstSend ? Completer<void>() : null;

  final sentAt = <DateTime>[];
  final sentFileNames = <String>[];
  final _updates = StreamController<BaleUpdate>.broadcast();
  final Object? sendError;
  final List<int> downloadBytes;
  final List<BaleMessage> loadHistoryMessages;
  final List<List<BaleMessage>> _loadHistoryBatches;
  final List<Object> _loadHistoryErrors;
  final Completer<void>? _firstSendGate;
  var loadHistoryCalls = 0;
  var downloadCalls = 0;

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
    if (_loadHistoryBatches.isNotEmpty) {
      return _loadHistoryBatches.removeAt(0);
    }
    return loadHistoryMessages;
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
    sentFileNames.add(file.name);
    final firstSendGate = _firstSendGate;
    if (firstSendGate != null && sentAt.length == 1) {
      await firstSendGate.future;
    }
    final error = sendError;
    if (error != null) throw error;
    return BaleMessage(
      chat: peer,
      senderId: session!.userId!,
      messageId: messageId ?? sentAt.length,
      date: sentAt.length,
    );
  }

  @override
  Future<List<int>> downloadFile({
    required int fileId,
    required int accessHash,
    void Function(List<int> chunk)? onChunk,
  }) async {
    downloadCalls += 1;
    return downloadBytes;
  }

  void addUpdate(BaleUpdate update) {
    _updates.add(update);
  }

  void releaseFirstSend() {
    final firstSendGate = _firstSendGate;
    if (firstSendGate != null && !firstSendGate.isCompleted) {
      firstSendGate.complete();
    }
  }
}

class _FakeTransport implements TunnelTransport {
  final sent = <OutgoingTunnelFile>[];
  final _incoming = StreamController<IncomingTunnelFile>.broadcast();
  Object? temporaryFailure;
  IncomingTunnelFile? startIncoming;

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
  Future<void> start() async {
    final incoming = startIncoming;
    if (incoming != null) {
      _incoming.add(incoming);
    }
  }

  void addIncoming(IncomingTunnelFile file) {
    _incoming.add(file);
  }
}

class _ChunkHarness {
  _ChunkHarness({
    required this.temp,
    required this.clientConfig,
    required this.relayCrypto,
    required this.transport,
    required this.chunkTransport,
  });

  final Directory temp;
  final BtunConfig clientConfig;
  final BtunCrypto relayCrypto;
  final _FakeTransport transport;
  final ChunkTransport chunkTransport;

  static Future<_ChunkHarness> create(
    String tempPrefix, {
    Duration ackDelay = const Duration(minutes: 1),
    Duration retryTimeout = const Duration(minutes: 1),
    Duration retryTick = const Duration(seconds: 10),
    int maxReorderChunks = 128,
    Duration receiveBaselineDelay = const Duration(seconds: 2),
    Duration? receiveGapTimeout,
    bool autoStart = true,
  }) async {
    final temp = await Directory.systemTemp.createTemp(tempPrefix);
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
      retryTimeout: retryTimeout,
      maxInFlight: 10,
      logger: const Logger(),
      flushDelay: const Duration(minutes: 1),
      ackDelay: ackDelay,
      retryTick: retryTick,
      maxReorderChunks: maxReorderChunks,
      receiveBaselineDelay: receiveBaselineDelay,
      receiveGapTimeout: receiveGapTimeout,
    );
    if (autoStart) await chunkTransport.start();
    final relayCrypto = await BtunCrypto.fromConfig(
      relayConfig,
      send: Direction.r2c,
      receive: Direction.c2r,
    );
    return _ChunkHarness(
      temp: temp,
      clientConfig: clientConfig,
      relayCrypto: relayCrypto,
      transport: transport,
      chunkTransport: chunkTransport,
    );
  }

  Future<void> addRemoteChunk(
    int sequenceNumber, {
    required List<int> payload,
    int? ackNumber,
  }) async {
    transport.addIncoming(
      await remoteFile(sequenceNumber, payload: payload, ackNumber: ackNumber),
    );
  }

  Future<void> addRemoteAckOnly(
    int sequenceNumber, {
    required int ackNumber,
  }) async {
    transport.addIncoming(
      await remoteAckFile(sequenceNumber, ackNumber: ackNumber),
    );
  }

  Future<void> addRemoteV4Chunk({
    required int uploadSequence,
    required int reliableSequence,
    required List<int> payload,
    int? ackNumber,
    List<AckRange> sackRanges = const <AckRange>[],
  }) async {
    transport.addIncoming(
      await remoteV4File(
        uploadSequence: uploadSequence,
        reliableSequence: reliableSequence,
        payload: payload,
        ackNumber: ackNumber,
        sackRanges: sackRanges,
      ),
    );
  }

  Future<void> addRemoteV4AckOnly({
    required int uploadSequence,
    required int ackNumber,
    List<AckRange> sackRanges = const <AckRange>[],
  }) async {
    transport.addIncoming(
      await remoteV4AckFile(
        uploadSequence: uploadSequence,
        ackNumber: ackNumber,
        sackRanges: sackRanges,
      ),
    );
  }

  Future<IncomingTunnelFile> remoteFile(
    int sequenceNumber, {
    required List<int> payload,
    int? ackNumber,
  }) async {
    final frames = <TunnelFrame>[
      if (ackNumber != null)
        TunnelFrame.ack(
          sessionId: clientConfig.sessionId,
          direction: Direction.r2c,
          ackNumber: ackNumber,
        ),
      TunnelFrame.data(
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        streamId: 1,
        sequenceNumber: sequenceNumber,
        payload: payload,
      ),
    ];
    final incoming = await relayCrypto.encrypt(
      PlainChunk(
        version: 4,
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        sequenceNumber: sequenceNumber,
        chunkEpoch: 'remote-test-epoch',
        reliableSequenceNumber: sequenceNumber,
        frames: frames,
      ),
    );
    return IncomingTunnelFile(
      messageId:
          'remote-$sequenceNumber-${DateTime.now().microsecondsSinceEpoch}',
      fileName: btunFileName(
        clientConfig.sessionId,
        Direction.r2c,
        sequenceNumber,
      ),
      bytes: incoming.encode(),
    );
  }

  Future<IncomingTunnelFile> remoteV4File({
    required int uploadSequence,
    required int reliableSequence,
    required List<int> payload,
    int? ackNumber,
    List<AckRange> sackRanges = const <AckRange>[],
  }) async {
    final frames = <TunnelFrame>[
      if (ackNumber != null)
        TunnelFrame.ack(
          sessionId: clientConfig.sessionId,
          direction: Direction.r2c,
          ackNumber: ackNumber,
          sackRanges: sackRanges,
        ),
      TunnelFrame.data(
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        streamId: 1,
        sequenceNumber: reliableSequence,
        payload: payload,
      ),
    ];
    final incoming = await relayCrypto.encrypt(
      PlainChunk(
        version: 4,
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        sequenceNumber: uploadSequence,
        chunkEpoch: 'remote-test-epoch',
        reliableSequenceNumber: reliableSequence,
        frames: frames,
      ),
    );
    return IncomingTunnelFile(
      messageId:
          'remote-v4-$uploadSequence-${DateTime.now().microsecondsSinceEpoch}',
      fileName: btunFileName(
        clientConfig.sessionId,
        Direction.r2c,
        uploadSequence,
      ),
      bytes: incoming.encode(),
    );
  }

  Future<IncomingTunnelFile> remoteAckFile(
    int sequenceNumber, {
    required int ackNumber,
  }) async {
    final incoming = await relayCrypto.encrypt(
      PlainChunk(
        version: 4,
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        sequenceNumber: sequenceNumber,
        chunkEpoch: 'remote-test-epoch',
        reliableSequenceNumber: 0,
        ackOnly: true,
        frames: [
          TunnelFrame.ack(
            sessionId: clientConfig.sessionId,
            direction: Direction.r2c,
            ackNumber: ackNumber,
          ),
        ],
      ),
    );
    return IncomingTunnelFile(
      messageId:
          'remote-ack-$sequenceNumber-${DateTime.now().microsecondsSinceEpoch}',
      fileName: btunFileName(
        clientConfig.sessionId,
        Direction.r2c,
        sequenceNumber,
      ),
      bytes: incoming.encode(),
    );
  }

  Future<IncomingTunnelFile> remoteV4AckFile({
    required int uploadSequence,
    required int ackNumber,
    List<AckRange> sackRanges = const <AckRange>[],
  }) async {
    final incoming = await relayCrypto.encrypt(
      PlainChunk(
        version: 4,
        sessionId: clientConfig.sessionId,
        direction: Direction.r2c,
        sequenceNumber: uploadSequence,
        chunkEpoch: 'remote-test-epoch',
        reliableSequenceNumber: 0,
        ackOnly: true,
        frames: [
          TunnelFrame.ack(
            sessionId: clientConfig.sessionId,
            direction: Direction.r2c,
            ackNumber: ackNumber,
            sackRanges: sackRanges,
          ),
        ],
      ),
    );
    return IncomingTunnelFile(
      messageId:
          'remote-v4-ack-$uploadSequence-${DateTime.now().microsecondsSinceEpoch}',
      fileName: btunFileName(
        clientConfig.sessionId,
        Direction.r2c,
        uploadSequence,
      ),
      bytes: incoming.encode(),
    );
  }

  Future<void> dispose() async {
    await chunkTransport.close();
    await temp.delete(recursive: true);
  }
}
