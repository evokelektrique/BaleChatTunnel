import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dart_lz4/dart_lz4.dart';

import 'config.dart';
import 'protocol.dart';

class KeyPairConfig {
  const KeyPairConfig({required this.publicKey, required this.privateKey});

  final String publicKey;
  final String privateKey;
}

class BtunCrypto {
  BtunCrypto._(this._algorithm, this._sendSecret, this._receiveSecret);

  final AesGcm _algorithm;
  final SecretKey _sendSecret;
  final SecretKey _receiveSecret;

  static Future<KeyPairConfig> generateKeyPair() async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    return KeyPairConfig(
      publicKey: base64Encode(publicKey.bytes),
      privateKey: base64Encode(privateBytes),
    );
  }

  static Future<BtunCrypto> fromConfig(
    BtunConfig config, {
    required Direction send,
    required Direction receive,
  }) async {
    final privateBytes = base64Decode(config.localPrivateKey);
    final peerBytes = base64Decode(config.peerPublicKey!);
    final local = SimpleKeyPairData(
      privateBytes,
      publicKey: SimplePublicKey(
        base64Decode(config.localPublicKey),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
    final peer = SimplePublicKey(peerBytes, type: KeyPairType.x25519);
    final shared = await X25519().sharedSecretKey(
      keyPair: local,
      remotePublicKey: peer,
    );
    final sharedBytes = await shared.extractBytes();
    final sendSecret = await _derive(sharedBytes, config.sessionId, send);
    final receiveSecret = await _derive(sharedBytes, config.sessionId, receive);
    return BtunCrypto._(AesGcm.with256bits(), sendSecret, receiveSecret);
  }

  Future<EncryptedChunkFile> encrypt(PlainChunk chunk) async {
    final nonce = _algorithm.newNonce();
    final plain = chunk.encode();
    final compressed = lz4FrameEncodeWithOptions(
      plain,
      options: Lz4FrameOptions(
        contentSize: plain.length,
        contentChecksum: true,
        compression: Lz4FrameCompression.fast,
      ),
    );
    final useCompression = compressed.length < plain.length;
    final metadata = EncryptedChunkMetadata(
      version: chunk.version,
      sessionId: chunk.sessionId,
      direction: chunk.direction,
      sequenceNumber: chunk.sequenceNumber,
      nonce: nonce,
      compressed: useCompression,
    );
    final box = await _algorithm.encrypt(
      useCompression ? compressed : plain,
      secretKey: _sendSecret,
      nonce: nonce,
      aad: metadata.aad(),
    );
    return EncryptedChunkFile(
      metadata: metadata,
      cipherText: box.cipherText,
      mac: box.mac.bytes,
    );
  }

  Future<PlainChunk> decrypt(EncryptedChunkFile file) async {
    final clear = await _algorithm.decrypt(
      SecretBox(
        file.cipherText,
        nonce: file.metadata.nonce,
        mac: Mac(file.mac),
      ),
      secretKey: _receiveSecret,
      aad: file.metadata.aad(),
    );
    if (!file.metadata.compressed) return PlainChunk.decode(clear);
    final decompressed = lz4FrameDecode(
      Uint8List.fromList(clear),
      maxOutputBytes: 16 * 1024 * 1024,
    );
    return PlainChunk.decode(decompressed);
  }

  static Future<SecretKey> _derive(
    List<int> sharedSecret,
    String sessionId,
    Direction direction,
  ) {
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(sharedSecret),
      nonce: utf8.encode('btun:$sessionId'),
      info: utf8.encode('btun:${direction.name}:v1'),
    );
  }
}
