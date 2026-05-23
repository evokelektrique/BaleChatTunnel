import 'dart:async';
import 'dart:io';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('relay buffers DATA that arrives in the same chunk as OPEN', () async {
    final temp = await Directory.systemTemp.createTemp('btun_relay_test_');
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close();
      await temp.delete(recursive: true);
    });

    final received = Completer<List<int>>();
    server.listen((socket) {
      final chunks = <int>[];
      socket.listen((data) {
        chunks.addAll(data);
        if (!received.isCompleted) received.complete(chunks);
        socket.add([0x6f, 0x6b]);
        unawaited(socket.close());
      }, onError: (_) {});
    }, onError: (_) {});

    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final sessionId = 'relaytest';
    final clientConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: sessionId,
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
    );
    final relayConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: sessionId,
      localPublicKey: relayKeys.publicKey,
      localPrivateKey: relayKeys.privateKey,
      peerPublicKey: clientKeys.publicKey,
    );
    final fakeTransport = _FakeTransport();
    final relayChunkTransport = ChunkTransport(
      transport: fakeTransport,
      crypto: await BtunCrypto.fromConfig(
        relayConfig,
        send: Direction.r2c,
        receive: Direction.c2r,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: sessionId,
      sendDirection: Direction.r2c,
      receiveDirection: Direction.c2r,
      chunkSize: relayConfig.chunkSize,
      retryTimeout: relayConfig.retryTimeout,
      maxInFlight: 1,
      logger: const Logger(),
      flushDelay: const Duration(milliseconds: 20),
      controlFlushDelay: const Duration(milliseconds: 20),
      ackDelay: const Duration(milliseconds: 20),
    );
    final relay = TcpRelay(
      chunkTransport: relayChunkTransport,
      policy: RelayPolicy(
        allowPorts: {server.port},
        blockPrivateIps: false,
        dnsOnRelay: true,
      ),
      logger: const Logger(),
    );
    await relayChunkTransport.start();
    await relay.start();

    final clientCrypto = await BtunCrypto.fromConfig(
      clientConfig,
      send: Direction.c2r,
      receive: Direction.r2c,
    );
    final chunk = await clientCrypto.encrypt(
      PlainChunk(
        version: 1,
        sessionId: sessionId,
        direction: Direction.c2r,
        sequenceNumber: 1,
        frames: [
          TunnelFrame.open(
            sessionId: sessionId,
            direction: Direction.c2r,
            streamId: 7,
            sequenceNumber: 1,
            host: InternetAddress.loopbackIPv4.address,
            port: server.port,
          ),
          TunnelFrame.data(
            sessionId: sessionId,
            direction: Direction.c2r,
            streamId: 7,
            sequenceNumber: 2,
            payload: [0x68, 0x69],
          ),
        ],
      ),
    );
    fakeTransport.addIncoming(
      IncomingTunnelFile(
        messageId: '1',
        fileName: btunFileName(sessionId, Direction.c2r, 1),
        bytes: chunk.encode(),
      ),
    );

    expect(await received.future.timeout(const Duration(seconds: 3)), [
      0x68,
      0x69,
    ]);
    await _waitFor(() => fakeTransport.sent.isNotEmpty);
    final readyChunk = EncryptedChunkFile.decode(
      fakeTransport.sent.first.bytes,
    );
    final readyPlain = await clientCrypto.decrypt(readyChunk);
    expect(
      readyPlain.frames.map((frame) => frame.type),
      contains(FrameType.ready),
    );

    await relay.close();
    await relayChunkTransport.close();
  });

  test('relay sends reset when OPEN cannot connect', () async {
    final temp = await Directory.systemTemp.createTemp('btun_relay_fail_test_');
    addTearDown(() async {
      await temp.delete(recursive: true);
    });

    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final sessionId = 'relayfail';
    final clientConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: sessionId,
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
    );
    final relayConfig = BtunConfig.defaults(profileDir: temp.path).copyWith(
      sessionId: sessionId,
      localPublicKey: relayKeys.publicKey,
      localPrivateKey: relayKeys.privateKey,
      peerPublicKey: clientKeys.publicKey,
    );
    final fakeTransport = _FakeTransport();
    final relayChunkTransport = ChunkTransport(
      transport: fakeTransport,
      crypto: await BtunCrypto.fromConfig(
        relayConfig,
        send: Direction.r2c,
        receive: Direction.c2r,
      ),
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: sessionId,
      sendDirection: Direction.r2c,
      receiveDirection: Direction.c2r,
      chunkSize: relayConfig.chunkSize,
      retryTimeout: relayConfig.retryTimeout,
      maxInFlight: 1,
      logger: const Logger(),
      controlFlushDelay: Duration.zero,
      ackDelay: const Duration(minutes: 1),
    );
    final relay = TcpRelay(
      chunkTransport: relayChunkTransport,
      policy: RelayPolicy(
        allowPorts: const {},
        blockPrivateIps: false,
        dnsOnRelay: true,
      ),
      logger: const Logger(),
    );
    await relayChunkTransport.start();
    await relay.start();

    final clientCrypto = await BtunCrypto.fromConfig(
      clientConfig,
      send: Direction.c2r,
      receive: Direction.r2c,
    );
    final chunk = await clientCrypto.encrypt(
      PlainChunk(
        version: 1,
        sessionId: sessionId,
        direction: Direction.c2r,
        sequenceNumber: 1,
        frames: [
          TunnelFrame.open(
            sessionId: sessionId,
            direction: Direction.c2r,
            streamId: 7,
            sequenceNumber: 1,
            host: 'example.com',
            port: 443,
          ),
        ],
      ),
    );
    fakeTransport.addIncoming(
      IncomingTunnelFile(
        messageId: '1',
        fileName: btunFileName(sessionId, Direction.c2r, 1),
        bytes: chunk.encode(),
      ),
    );

    await _waitFor(() => fakeTransport.sent.isNotEmpty);
    final resetChunk = EncryptedChunkFile.decode(
      fakeTransport.sent.first.bytes,
    );
    final resetPlain = await clientCrypto.decrypt(resetChunk);
    expect(
      resetPlain.frames.map((frame) => frame.type),
      contains(FrameType.reset),
    );

    await relay.close();
    await relayChunkTransport.close();
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeTransport implements TunnelTransport {
  final sent = <OutgoingTunnelFile>[];
  final _incoming = StreamController<IncomingTunnelFile>.broadcast();

  void addIncoming(IncomingTunnelFile file) => _incoming.add(file);

  @override
  bool get isBackingOff => false;

  @override
  Future<void> close() async {
    await _incoming.close();
  }

  @override
  Stream<IncomingTunnelFile> incomingFiles() => _incoming.stream;

  @override
  Future<void> sendFile(OutgoingTunnelFile file) async {
    sent.add(file);
  }

  @override
  Future<void> start() async {}
}
