import 'dart:math';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('binary v4 chunk round trips all frame types', () {
    final chunk = PlainChunk(
      version: 4,
      sessionId: 'ab12cd34',
      direction: Direction.c2r,
      sequenceNumber: 7,
      chunkEpoch: 'epoch-all',
      reliableSequenceNumber: 5,
      frames: [
        TunnelFrame.open(
          sessionId: 'ab12cd34',
          direction: Direction.c2r,
          streamId: 42,
          sequenceNumber: 1,
          host: 'example.com',
          port: 443,
        ),
        TunnelFrame.data(
          sessionId: 'ab12cd34',
          direction: Direction.c2r,
          streamId: 42,
          sequenceNumber: 2,
          payload: [1, 2, 3],
        ),
        TunnelFrame.ack(
          sessionId: 'ab12cd34',
          direction: Direction.c2r,
          ackNumber: 99,
        ),
        TunnelFrame.close(
          sessionId: 'ab12cd34',
          direction: Direction.c2r,
          streamId: 42,
          sequenceNumber: 3,
        ),
        TunnelFrame.reset(
          sessionId: 'ab12cd34',
          direction: Direction.c2r,
          streamId: 42,
          sequenceNumber: 4,
          message: 'boom',
        ),
      ],
    );

    final decoded = PlainChunk.decode(chunk.encode());

    expect(chunk.encode().first, isNot('{'.codeUnitAt(0)));
    expect(decoded.version, 4);
    expect(decoded.sessionId, 'ab12cd34');
    expect(decoded.direction, Direction.c2r);
    expect(decoded.sequenceNumber, 7);
    expect(decoded.chunkEpoch, 'epoch-all');
    expect(decoded.reliableSequenceNumber, 5);
    expect(decoded.frames.map((frame) => frame.type), [
      FrameType.open,
      FrameType.data,
      FrameType.ack,
      FrameType.close,
      FrameType.reset,
    ]);
    expect(decoded.frames[0].host, 'example.com');
    expect(decoded.frames[0].port, 443);
    expect(decoded.frames[1].payload, [1, 2, 3]);
    expect(decoded.frames[2].ackNumber, 99);
    expect(decoded.frames[4].message, 'boom');
  });

  test('binary v4 chunk round trips reliable sequence metadata', () {
    final chunk = PlainChunk(
      version: 4,
      sessionId: 'v4session',
      direction: Direction.r2c,
      sequenceNumber: 12,
      chunkEpoch: 'epoch-1',
      reliableSequenceNumber: 0,
      ackOnly: true,
      frames: [
        TunnelFrame.ack(
          sessionId: 'v4session',
          direction: Direction.r2c,
          ackNumber: 8,
          sackRanges: const [AckRange(start: 10, end: 11)],
        ),
      ],
    );

    final decoded = PlainChunk.decode(chunk.encode());

    expect(decoded.version, 4);
    expect(decoded.sequenceNumber, 12);
    expect(decoded.chunkEpoch, 'epoch-1');
    expect(decoded.reliableSequenceNumber, 0);
    expect(decoded.ackOnly, isTrue);
    expect(decoded.frames.single.sackRanges.single.start, 10);
    expect(decoded.frames.single.sackRanges.single.end, 11);
  });

  test('legacy JSON/base64 plain chunk decode is rejected', () {
    expect(
      () => PlainChunk.decode('{ "version": 1 }'.codeUnits),
      throwsFormatException,
    );
  });

  test('legacy JSON/base64 encrypted wrapper decode is rejected', () {
    expect(
      () => EncryptedChunkFile.decode('{ "metadata": {} }'.codeUnits),
      throwsFormatException,
    );
  });

  test('encrypted v4 round trips with compression enabled', () async {
    final clientKeys = await BtunCrypto.generateKeyPair();
    final relayKeys = await BtunCrypto.generateKeyPair();
    final clientConfig = BtunConfig.defaults().copyWith(
      sessionId: 'compress',
      localPublicKey: clientKeys.publicKey,
      localPrivateKey: clientKeys.privateKey,
      peerPublicKey: relayKeys.publicKey,
    );
    final relayConfig = BtunConfig.defaults().copyWith(
      sessionId: 'compress',
      localPublicKey: relayKeys.publicKey,
      localPrivateKey: relayKeys.privateKey,
      peerPublicKey: clientKeys.publicKey,
    );
    final sender = await BtunCrypto.fromConfig(
      clientConfig,
      send: Direction.c2r,
      receive: Direction.r2c,
    );
    final receiver = await BtunCrypto.fromConfig(
      relayConfig,
      send: Direction.r2c,
      receive: Direction.c2r,
    );
    final chunk = PlainChunk(
      version: 4,
      sessionId: 'compress',
      direction: Direction.c2r,
      sequenceNumber: 1,
      chunkEpoch: 'compress-epoch',
      reliableSequenceNumber: 1,
      frames: [
        TunnelFrame.data(
          sessionId: 'compress',
          direction: Direction.c2r,
          streamId: 1,
          sequenceNumber: 1,
          payload: List<int>.filled(8192, 65),
        ),
      ],
    );

    final encrypted = await sender.encrypt(chunk);
    final decoded = EncryptedChunkFile.decode(encrypted.encode());
    final plain = await receiver.decrypt(decoded);

    expect(encrypted.metadata.version, 4);
    expect(encrypted.metadata.chunkEpoch, 'compress-epoch');
    expect(encrypted.metadata.compressed, isTrue);
    expect(encrypted.encode().first, isNot('{'.codeUnitAt(0)));
    expect(plain.frames.single.payload, List<int>.filled(8192, 65));
  });

  test(
    'encrypted v4 round trips uncompressed when compression is not smaller',
    () async {
      final clientKeys = await BtunCrypto.generateKeyPair();
      final relayKeys = await BtunCrypto.generateKeyPair();
      final clientConfig = BtunConfig.defaults().copyWith(
        sessionId: 'raw',
        localPublicKey: clientKeys.publicKey,
        localPrivateKey: clientKeys.privateKey,
        peerPublicKey: relayKeys.publicKey,
      );
      final relayConfig = BtunConfig.defaults().copyWith(
        sessionId: 'raw',
        localPublicKey: relayKeys.publicKey,
        localPrivateKey: relayKeys.privateKey,
        peerPublicKey: clientKeys.publicKey,
      );
      final sender = await BtunCrypto.fromConfig(
        clientConfig,
        send: Direction.c2r,
        receive: Direction.r2c,
      );
      final receiver = await BtunCrypto.fromConfig(
        relayConfig,
        send: Direction.r2c,
        receive: Direction.c2r,
      );
      final random = Random(1);
      final payload = List<int>.generate(4096, (_) => random.nextInt(256));
      final chunk = PlainChunk(
        version: 4,
        sessionId: 'raw',
        direction: Direction.c2r,
        sequenceNumber: 1,
        chunkEpoch: 'raw-epoch',
        reliableSequenceNumber: 1,
        frames: [
          TunnelFrame.data(
            sessionId: 'raw',
            direction: Direction.c2r,
            streamId: 1,
            sequenceNumber: 1,
            payload: payload,
          ),
        ],
      );

      final encrypted = await sender.encrypt(chunk);
      final plain = await receiver.decrypt(
        EncryptedChunkFile.decode(encrypted.encode()),
      );

      expect(encrypted.metadata.compressed, isFalse);
      expect(plain.frames.single.payload, payload);
    },
  );

  test('btun file names carry session direction and sequence', () {
    expect(
      btunFileName('ab12cd34', Direction.r2c, 1),
      'btun_ab12cd34_r2c_00000001.bin',
    );
    expect(isBtunFileName('btun_ab12cd34_r2c_00000001.bin'), isTrue);
    expect(isBtunFileName('photo.jpg'), isFalse);
  });
}
