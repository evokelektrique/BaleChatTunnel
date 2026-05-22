import 'dart:convert';
import 'dart:math';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('binary chunk round trips all frame types', () {
    final chunk = PlainChunk(
      version: 2,
      sessionId: 'ab12cd34',
      direction: Direction.c2r,
      sequenceNumber: 7,
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
    expect(decoded.version, 2);
    expect(decoded.sessionId, 'ab12cd34');
    expect(decoded.direction, Direction.c2r);
    expect(decoded.sequenceNumber, 7);
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

  test('legacy JSON/base64 plain chunk decode fallback remains readable', () {
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'session_id': 'legacy',
        'direction': 'r2c',
        'sequence_number': 11,
        'frames': [
          {
            'version': 1,
            'session_id': 'legacy',
            'direction': 'r2c',
            'stream_id': 5,
            'sequence_number': 6,
            'ack_number': 0,
            'type': 'data',
            'payload': base64Encode([7, 8, 9]),
          },
        ],
      }),
    );

    final decoded = PlainChunk.decode(bytes);

    expect(decoded.version, 1);
    expect(decoded.sessionId, 'legacy');
    expect(decoded.direction, Direction.r2c);
    expect(decoded.frames.single.payload, [7, 8, 9]);
  });

  test(
    'legacy JSON/base64 encrypted wrapper decode fallback remains readable',
    () {
      final bytes = utf8.encode(
        jsonEncode({
          'metadata': {
            'magic': 'btun',
            'version': 1,
            'session_id': 'legacy',
            'direction': 'c2r',
            'sequence_number': 12,
            'message_type': 'chunk',
            'nonce': base64Encode(List<int>.filled(12, 1)),
          },
          'ciphertext': base64Encode([1, 2, 3]),
          'mac': base64Encode(List<int>.filled(16, 2)),
        }),
      );

      final decoded = EncryptedChunkFile.decode(bytes);

      expect(decoded.metadata.version, 1);
      expect(decoded.metadata.compressed, isFalse);
      expect(decoded.metadata.nonce, List<int>.filled(12, 1));
      expect(decoded.cipherText, [1, 2, 3]);
      expect(decoded.mac, List<int>.filled(16, 2));
    },
  );

  test('encrypted v2 round trips with compression enabled', () async {
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
      version: 2,
      sessionId: 'compress',
      direction: Direction.c2r,
      sequenceNumber: 1,
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

    expect(encrypted.metadata.version, 2);
    expect(encrypted.metadata.compressed, isTrue);
    expect(encrypted.encode().first, isNot('{'.codeUnitAt(0)));
    expect(plain.frames.single.payload, List<int>.filled(8192, 65));
  });

  test(
    'encrypted v2 round trips uncompressed when compression is not smaller',
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
        version: 2,
        sessionId: 'raw',
        direction: Direction.c2r,
        sequenceNumber: 1,
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
