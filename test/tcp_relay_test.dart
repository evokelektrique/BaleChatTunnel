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
        version: 4,
        sessionId: sessionId,
        direction: Direction.c2r,
        sequenceNumber: 1,
        chunkEpoch: 'client-test-epoch',
        reliableSequenceNumber: 1,
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

    await relay.close();
    await relayChunkTransport.close();
  });

  test('relay destroys active sockets when chunk frames close', () async {
    final temp = await Directory.systemTemp.createTemp(
      'btun_relay_close_test_',
    );
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close();
      await temp.delete(recursive: true);
    });

    final accepted = Completer<void>();
    final socketDone = Completer<void>();
    server.listen((socket) {
      if (!accepted.isCompleted) accepted.complete();
      socket.listen(
        (_) {},
        onDone: () {
          if (!socketDone.isCompleted) socketDone.complete();
        },
        onError: (_) {
          if (!socketDone.isCompleted) socketDone.complete();
        },
        cancelOnError: true,
      );
    }, onError: (_) {});

    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final sessionId = 'relayclosetest';
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
        version: 4,
        sessionId: sessionId,
        direction: Direction.c2r,
        sequenceNumber: 1,
        chunkEpoch: 'client-test-epoch',
        reliableSequenceNumber: 1,
        frames: [
          TunnelFrame.open(
            sessionId: sessionId,
            direction: Direction.c2r,
            streamId: 7,
            sequenceNumber: 1,
            host: InternetAddress.loopbackIPv4.address,
            port: server.port,
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
    await accepted.future.timeout(const Duration(seconds: 3));

    await relayChunkTransport.close();
    await socketDone.future.timeout(const Duration(seconds: 3));

    await relay.close();
  });
}

class _FakeTransport implements TunnelTransport {
  final sent = <OutgoingTunnelFile>[];
  final _incoming = StreamController<IncomingTunnelFile>.broadcast();

  void addIncoming(IncomingTunnelFile file) => _incoming.add(file);

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
  }

  @override
  Future<void> start() async {}
}
