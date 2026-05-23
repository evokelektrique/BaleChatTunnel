import 'dart:async';
import 'dart:io';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('client open waits for relay ready', () async {
    final fixture = await _ClientFixture.create('readytest');
    addTearDown(fixture.close);

    var completed = false;
    final openFuture = fixture.client.open('example.com', 443).then((stream) {
      completed = true;
      return stream;
    });

    await fixture.waitForSent();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(completed, isFalse);

    final streamId = await fixture.sentStreamId();
    await fixture.addRelayFrame(
      TunnelFrame.ready(
        sessionId: fixture.sessionId,
        direction: Direction.r2c,
        streamId: streamId,
        sequenceNumber: 1,
      ),
    );

    final stream = await openFuture.timeout(const Duration(seconds: 3));
    expect(completed, isTrue);
    await stream.close(localOnly: true);
  });

  test('client open fails when relay resets before ready', () async {
    final fixture = await _ClientFixture.create('resettest');
    addTearDown(fixture.close);

    final openFuture = fixture.client.open('example.com', 443);
    final expectation = expectLater(openFuture, throwsException);

    await fixture.waitForSent();
    final streamId = await fixture.sentStreamId();
    await fixture.addRelayFrame(
      TunnelFrame.reset(
        sessionId: fixture.sessionId,
        direction: Direction.r2c,
        streamId: streamId,
        sequenceNumber: 1,
        message: 'connect failed',
      ),
    );

    await expectation;
  });

  test('SOCKS success waits for relay ready', () async {
    final fixture = await _ClientFixture.create('sockstest');
    final socks = Socks5Server(
      host: InternetAddress.loopbackIPv4.address,
      port: 0,
      client: fixture.client,
      logger: const Logger(),
    );
    await socks.start();
    addTearDown(() async {
      await socks.close();
      await fixture.close();
    });

    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      socks.boundPort,
    );
    addTearDown(socket.destroy);
    final reader = _SocketReader(socket);
    addTearDown(reader.cancel);

    socket.add([0x05, 0x01, 0x00]);
    expect(await reader.readExactly(2), [0x05, 0x00]);
    socket.add([
      0x05,
      0x01,
      0x00,
      0x03,
      11,
      ...'example.com'.codeUnits,
      0x01,
      0xbb,
    ]);

    await fixture.waitForSent();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reader.available, 0);

    final streamId = await fixture.sentStreamId();
    await fixture.addRelayFrame(
      TunnelFrame.ready(
        sessionId: fixture.sessionId,
        direction: Direction.r2c,
        streamId: streamId,
        sequenceNumber: 1,
      ),
    );

    expect(await reader.readExactly(10), [
      0x05,
      0x00,
      0x00,
      0x01,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
  });
}

class _SocketReader {
  _SocketReader(Socket socket) {
    _sub = socket.listen(
      _onData,
      onError: (Object error, StackTrace stack) {
        final waiter = _waiter;
        if (waiter != null && !waiter.isCompleted) {
          waiter.completeError(error, stack);
        }
      },
      onDone: () {
        _done = true;
        final waiter = _waiter;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete();
        }
      },
      cancelOnError: true,
    );
  }

  final _buffer = <int>[];
  late final StreamSubscription<List<int>> _sub;
  Completer<void>? _waiter;
  var _done = false;

  int get available => _buffer.length;

  Future<List<int>> readExactly(int length) async {
    while (_buffer.length < length) {
      if (_done) throw const SocketException('socket closed');
      _waiter = Completer<void>();
      await _waiter!.future;
      _waiter = null;
    }
    final out = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return out;
  }

  void _onData(List<int> data) {
    _buffer.addAll(data);
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  Future<void> cancel() => _sub.cancel();
}

class _ClientFixture {
  _ClientFixture({
    required this.sessionId,
    required this.transport,
    required this.chunkTransport,
    required this.client,
    required this.clientCrypto,
    required this.relayCrypto,
    required this.temp,
  });

  final String sessionId;
  final _FakeTransport transport;
  final ChunkTransport chunkTransport;
  final BtunClient client;
  final BtunCrypto clientCrypto;
  final BtunCrypto relayCrypto;
  final Directory temp;

  static Future<_ClientFixture> create(String sessionId) async {
    final temp = await Directory.systemTemp.createTemp('btun_client_test_');
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
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
    final transport = _FakeTransport();
    final clientCrypto = await BtunCrypto.fromConfig(
      clientConfig,
      send: Direction.c2r,
      receive: Direction.r2c,
    );
    final relayCrypto = await BtunCrypto.fromConfig(
      relayConfig,
      send: Direction.r2c,
      receive: Direction.c2r,
    );
    final chunkTransport = ChunkTransport(
      transport: transport,
      crypto: clientCrypto,
      stateDb: StateDb.open('${temp.path}/state.json'),
      sessionId: sessionId,
      sendDirection: Direction.c2r,
      receiveDirection: Direction.r2c,
      chunkSize: clientConfig.chunkSize,
      retryTimeout: clientConfig.retryTimeout,
      maxInFlight: 1,
      logger: const Logger(),
      controlFlushDelay: Duration.zero,
      ackDelay: const Duration(minutes: 1),
    );
    await chunkTransport.start();
    final client = BtunClient(
      config: clientConfig,
      chunkTransport: chunkTransport,
    );
    return _ClientFixture(
      sessionId: sessionId,
      transport: transport,
      chunkTransport: chunkTransport,
      client: client,
      clientCrypto: clientCrypto,
      relayCrypto: relayCrypto,
      temp: temp,
    );
  }

  Future<void> waitForSent() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (transport.sent.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('no sent frame');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<int> sentStreamId() async {
    final sent = EncryptedChunkFile.decode(transport.sent.first.bytes);
    final plain = await relayCrypto.decrypt(sent);
    return plain.frames.first.streamId;
  }

  Future<void> addRelayFrame(TunnelFrame frame) async {
    final encrypted = await relayCrypto.encrypt(
      PlainChunk(
        version: 1,
        sessionId: sessionId,
        direction: Direction.r2c,
        sequenceNumber: DateTime.now().millisecondsSinceEpoch,
        frames: [frame],
      ),
    );
    transport.addIncoming(
      IncomingTunnelFile(
        messageId: frame.sequenceNumber.toString(),
        fileName: btunFileName(sessionId, Direction.r2c, frame.sequenceNumber),
        bytes: encrypted.encode(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Future<void> close() async {
    await client.close();
    await chunkTransport.close();
    await temp.delete(recursive: true);
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
