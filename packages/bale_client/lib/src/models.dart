import 'dart:convert';
import 'dart:typed_data';

enum BaleChatType {
  unknown(0),
  private(1),
  group(2),
  channel(3),
  bot(4),
  superGroup(5);

  const BaleChatType(this.value);
  final int value;
}

enum BalePeerType {
  unknown(0),
  private(1),
  group(2);

  const BalePeerType(this.value);
  final int value;
}

enum BaleSendType {
  unknown(0),
  photo(1),
  video(2),
  voice(3),
  gif(4),
  audio(5),
  document(6),
  sticker(7),
  crowdfunding(8);

  const BaleSendType(this.value);
  final int value;
}

enum BaleAuthError {
  unknown,
  numberBanned,
  authLimit,
  wrongCode,
  passwordNeeded,
  signUpNeeded,
  wrongPassword,
  rateLimit,
  invalid,
}

class BaleException implements Exception {
  const BaleException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => code == null ? message : '$message (code $code)';
}

class BaleHttpException extends BaleException {
  const BaleHttpException(
    super.message, {
    required this.stage,
    required this.statusCode,
    required this.host,
    required this.elapsed,
    this.body = '',
    this.headers = const {},
  });

  final String stage;
  final int statusCode;
  final String host;
  final Duration elapsed;
  final String body;
  final Map<String, String> headers;
}

class BaleAuthException extends BaleException {
  const BaleAuthException(super.message, this.authError, {super.code});

  final BaleAuthError authError;
}

class PhoneAuthResponse {
  const PhoneAuthResponse({
    required this.transactionHash,
    required this.isRegistered,
  });

  final String transactionHash;
  final bool isRegistered;
}

class ValidateCodeResponse {
  const ValidateCodeResponse({required this.jwt, this.userBytes});

  final String jwt;
  final Uint8List? userBytes;
}

class BaleSession {
  const BaleSession({
    required this.accessToken,
    this.jwt,
    this.userId,
    this.authId,
    this.authSid,
    this.expiresAt,
  });

  final String accessToken;
  final String? jwt;
  final int? userId;
  final String? authId;
  final int? authSid;
  final DateTime? expiresAt;

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'jwt': jwt,
    'userId': userId,
    'authId': authId,
    'authSid': authSid,
    'expiresAt': expiresAt?.toIso8601String(),
  };

  static BaleSession fromJson(Map<String, Object?> json) => BaleSession(
    accessToken: json['accessToken'] as String,
    jwt: json['jwt'] as String?,
    userId: json['userId'] as int?,
    authId: json['authId'] as String?,
    authSid: json['authSid'] as int?,
    expiresAt: json['expiresAt'] == null
        ? null
        : DateTime.parse(json['expiresAt']! as String),
  );
}

class BalePeer {
  const BalePeer({required this.id, required this.type, this.accessHash});

  const BalePeer.private(this.id, {this.accessHash})
    : type = BalePeerType.private;

  const BalePeer.group(this.id, {this.accessHash}) : type = BalePeerType.group;

  final int id;
  final BalePeerType type;
  final int? accessHash;
}

class BaleUser {
  const BaleUser({
    required this.id,
    this.name = '',
    this.nick = '',
    this.accessHash = 0,
    this.phone = '',
  });

  final int id;
  final String name;
  final String nick;
  final int accessHash;
  final String phone;

  String get displayName {
    if (name.isNotEmpty) return name;
    if (nick.isNotEmpty) return '@$nick';
    return id.toString();
  }

  BalePeer get peer => BalePeer.private(id, accessHash: accessHash);
}

class BaleMessage {
  const BaleMessage({
    required this.chat,
    required this.senderId,
    required this.messageId,
    required this.date,
    this.text,
    this.document,
  });

  final BalePeer chat;
  final int senderId;
  final int messageId;
  final int date;
  final String? text;
  final BaleFileDetails? document;
}

sealed class BaleUpdate {
  const BaleUpdate();
}

class BaleMessageUpdate extends BaleUpdate {
  const BaleMessageUpdate(this.message);

  final BaleMessage message;
}

class BaleMessageSentUpdate extends BaleUpdate {
  const BaleMessageSentUpdate(this.info);

  final BaleInfoMessage info;
}

class BaleRawUpdate extends BaleUpdate {
  const BaleRawUpdate(this.bytes, {this.fields = const {}});

  final Uint8List bytes;
  final Map<String, Object?> fields;
}

class BaleConnectionStateUpdate extends BaleUpdate {
  const BaleConnectionStateUpdate(this.state);

  final BaleConnectionState state;
}

class BaleInfoMessage {
  const BaleInfoMessage({
    required this.peer,
    required this.messageId,
    required this.date,
  });

  final BalePeer peer;
  final int messageId;
  final int date;
}

enum BaleConnectionState {
  disconnected,
  connecting,
  ready,
  reconnecting,
  tokenExpired,
  versionMismatch,
}

class BaleFileUploadInfo {
  const BaleFileUploadInfo({
    required this.fileId,
    required this.url,
    required this.chunkSize,
  });

  final int fileId;
  final String url;
  final int chunkSize;
}

class BaleFileUrl {
  const BaleFileUrl({
    required this.fileId,
    required this.url,
    required this.timeout,
    required this.chunkSize,
  });

  final int fileId;
  final String url;
  final int timeout;
  final int chunkSize;
}

class BaleFileDetails {
  const BaleFileDetails({
    required this.fileId,
    required this.accessHash,
    required this.name,
    required this.size,
    required this.mimeType,
    this.caption,
  });

  final int fileId;
  final int accessHash;
  final String name;
  final int size;
  final String mimeType;
  final String? caption;
}

Map<String, Object?>? decodeJwtPayload(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  final normalized = base64Url.normalize(parts[1]);
  final decoded = utf8.decode(base64Url.decode(normalized));
  final value = jsonDecode(decoded);
  return value is Map<String, Object?> ? value : null;
}

BaleSession sessionFromJwt({required String accessToken, String? jwt}) {
  final payload = decodeJwtPayload(jwt ?? accessToken);
  final inner = payload?['payload'];
  final payloadMap = inner is Map<String, Object?> ? inner : payload;
  final exp = payload?['exp'];
  return BaleSession(
    accessToken: accessToken,
    jwt: jwt,
    userId: _asInt(payloadMap?['user_id'] ?? payloadMap?['userId']),
    authId: payloadMap?['auth_id']?.toString(),
    authSid: _asInt(payloadMap?['auth_sid']),
    expiresAt: exp is int
        ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true)
        : null,
  );
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}
