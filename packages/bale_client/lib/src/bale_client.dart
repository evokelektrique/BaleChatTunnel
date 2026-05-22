import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'constants.dart';
import 'file_input.dart';
import 'grpc_web.dart';
import 'models.dart';
import 'protobuf.dart';
import 'storage.dart';
import 'transports.dart';

const baleBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/135.0.0.0 Safari/537.36';

class BaleClient {
  BaleClient({
    BaleCredentialsStore? credentialsStore,
    http.Client? httpClient,
    BaleWebSocketConnector? webSocketConnector,
    Uri? grpcBaseUri,
    Uri? wsUri,
    Random? random,
  }) : credentialsStore = credentialsStore ?? MemoryBaleCredentialsStore(),
       _http = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _connectWebSocket = webSocketConnector ?? defaultBaleWebSocketConnector,
       _grpcBaseUri = grpcBaseUri ?? Uri.parse(baleGrpcBaseUrl),
       _wsUri = wsUri ?? Uri.parse(baleWsUrl),
       _random = random ?? Random.secure();

  final BaleCredentialsStore credentialsStore;
  final http.Client _http;
  final bool _ownsHttpClient;
  final BaleWebSocketConnector _connectWebSocket;
  final Uri _grpcBaseUri;
  final Uri _wsUri;
  final Random _random;

  final StreamController<BaleUpdate> _updates =
      StreamController<BaleUpdate>.broadcast();
  final Map<int, _PendingRpc> _pending = {};

  BaleSession? _session;
  BaleWebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _pingTimer;
  Timer? _presenceTimer;
  Timer? _reconnectTimer;
  Completer<void>? _connectCompleter;
  var _requestId = 0;
  var _pingId = 0;
  var _subscribeId = -1;
  var _reconnectAttempt = 0;
  var _closedByUser = false;
  var _ready = false;
  DateTime? _lastInboundAt;

  Stream<BaleUpdate> get updates => _updates.stream;
  BaleSession? get session => _session;
  bool get isConnected => _ready;

  Future<BaleSession?> restoreSession({bool connect = false}) async {
    final stored = await credentialsStore.read();
    if (stored == null) return null;
    _session = stored;
    if (connect) await this.connect();
    return stored;
  }

  Future<PhoneAuthResponse> startPhoneAuth(String phone) async {
    final payload = _buildStartPhoneAuth(phone);
    final bytes = await _grpcCall(serviceAuth, 'StartPhoneAuth', payload);
    return _decodeStartPhoneAuth(bytes);
  }

  Future<BaleSession> validateCode({
    required String transactionHash,
    required String code,
  }) async {
    final payload = ProtoWriter()
        .string(1, transactionHash)
        .string(2, code)
        .bytes(3, ProtoWriter().boolValue(1, true).build())
        .build();
    final response = await _authWithErrorMapping(
      () => _grpcCall(serviceAuth, 'ValidateCode', payload),
    );
    return _saveAuthResponse(response);
  }

  Future<BaleSession> validatePassword({
    required String transactionHash,
    required String password,
  }) async {
    final payload = ProtoWriter()
        .string(1, transactionHash)
        .string(2, password)
        .bytes(3, ProtoWriter().boolValue(1, true).build())
        .build();
    final response = await _authWithErrorMapping(
      () => _grpcCall(serviceAuth, 'ValidatePassword', payload),
    );
    return _saveAuthResponse(response);
  }

  Future<BaleSession> signUp({
    required String transactionHash,
    required String name,
  }) async {
    final payload = ProtoWriter()
        .string(1, transactionHash)
        .string(2, name)
        .build();
    final response = await _authWithErrorMapping(
      () => _grpcCall(serviceAuth, 'SignUp', payload),
    );
    return _saveAuthResponse(response);
  }

  Future<void> logout({bool remote = false}) async {
    final token = _session?.accessToken;
    if (remote && token != null && token.isNotEmpty) {
      try {
        await _grpcCall(serviceAuth, 'SignOut', Uint8List(0), token: token);
      } catch (_) {
        // Local credential removal is the important part of logout.
      }
    }
    await disconnect();
    _session = null;
    await credentialsStore.clear();
  }

  Future<List<BaleUser>> getContacts() async {
    final token = _requireSession().accessToken;
    final response = await _grpcCall(
      serviceUsers,
      'GetContacts',
      ProtoWriter().string(1, '').build(),
      token: token,
    );
    final contacts = _decodeGetContactsResponse(response);
    if (contacts.userPeers.isEmpty) {
      final users = contacts.inlineUsers;
      users.sort((a, b) => a.displayName.compareTo(b.displayName));
      return users;
    }

    final users = await loadUsers(contacts.userPeers);
    users.sort((a, b) => a.displayName.compareTo(b.displayName));
    return users;
  }

  Future<List<BaleUser>> loadUsers(List<BaleUserPeerRef> peers) async {
    if (peers.isEmpty) return const [];
    final token = _requireSession().accessToken;
    final response = await _grpcCall(
      serviceUsers,
      'LoadUsers',
      _buildLoadUsersRequest(peers),
      token: token,
    );
    final users = _decodeLoadUsersResponse(response);
    final hashesById = {for (final peer in peers) peer.uid: peer.accessHash};
    return [
      for (final user in users)
        BaleUser(
          id: user.id,
          name: user.name,
          nick: user.nick,
          accessHash: user.accessHash != 0
              ? user.accessHash
              : hashesById[user.id] ?? 0,
          phone: user.phone,
        ),
    ];
  }

  Future<List<BaleMessage>> loadHistory({
    required BalePeer peer,
    int limit = 20,
    int offsetDate = 9223372036854775807,
    int loadMode = 2,
  }) async {
    final response = await _rpcCall(
      serviceMessaging,
      'LoadHistory',
      ProtoWriter()
          .bytes(1, _buildPeer(peer))
          .int64(2, offsetDate)
          .int32(4, loadMode)
          .int32(5, limit)
          .build(),
    );
    final messages = _decodeHistoryResponse(response, peer);
    messages.sort((a, b) => b.date.compareTo(a.date));
    return messages;
  }

  Future<void> connect() async {
    final token = _requireSession().accessToken;
    if (_ready || _socket != null) await disconnect();
    _closedByUser = false;
    _emitState(BaleConnectionState.connecting);
    final ready = Completer<void>();
    _connectCompleter = ready;

    final socket = await _connectWebSocket(_wsUri, {
      'Cookie': 'access_token=$token',
      'Origin': baleOrigin,
      'User-Agent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
    });
    _socket = socket;
    _lastInboundAt = DateTime.now();
    _socketSub = socket.stream.listen(
      _handleSocketMessage,
      onError: (_) => _handleSocketClosed(),
      onDone: _handleSocketClosed,
      cancelOnError: true,
    );
    socket.add(_encodeHandshake());
    try {
      await ready.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw const BaleException('Timed out waiting for Bale handshake');
        },
      );
    } catch (_) {
      if (_connectCompleter == ready) {
        _connectCompleter = null;
        await disconnect();
      }
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _closedByUser = true;
    _ready = false;
    _pingTimer?.cancel();
    _presenceTimer?.cancel();
    _reconnectTimer?.cancel();
    final connectCompleter = _connectCompleter;
    _connectCompleter = null;
    if (connectCompleter != null && !connectCompleter.isCompleted) {
      connectCompleter.completeError(BaleException('WebSocket disconnected'));
    }
    _pingTimer = null;
    _presenceTimer = null;
    _reconnectTimer = null;
    await _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) await socket.close();
    _drainPending(BaleException('WebSocket disconnected'));
    _emitState(BaleConnectionState.disconnected);
  }

  Future<BaleMessage> sendText({
    required BalePeer peer,
    required String text,
    int? messageId,
  }) async {
    final rid = messageId ?? DateTime.now().millisecondsSinceEpoch;
    final payload = _buildSendMessage(peer, rid, _buildTextContent(text));
    final response = await _rpcCall(serviceMessaging, 'SendMessage', payload);
    final date = _decodeSendMessageDate(response);
    return BaleMessage(
      chat: peer,
      senderId: _session?.userId ?? 0,
      messageId: rid,
      date: date,
      text: text,
    );
  }

  Future<BaleFileDetails> uploadFile(
    BaleFileInput file, {
    BalePeer? peer,
    BaleSendType sendType = BaleSendType.document,
    void Function(int sent, int total)? onProgress,
  }) async {
    final size = await file.size;
    final upload = await getFileUploadUrl(
      size: size,
      name: file.name,
      mimeType: file.mimeType,
      peer: peer,
      sendType: sendType,
    );
    await _upload(file, upload, size, onProgress);
    return BaleFileDetails(
      fileId: upload.fileId,
      accessHash: _session?.userId ?? 0,
      name: file.name,
      size: size,
      mimeType: file.mimeType,
    );
  }

  Future<BaleMessage> sendDocument({
    required BalePeer peer,
    required BaleFileInput file,
    String? caption,
    int? messageId,
    void Function(int sent, int total)? onProgress,
  }) async {
    final details = await uploadFile(
      file,
      peer: peer,
      sendType: BaleSendType.document,
      onProgress: onProgress,
    );
    final rid = messageId ?? DateTime.now().millisecondsSinceEpoch;
    final payload = _buildSendMessage(
      peer,
      rid,
      _buildDocumentContent(details, caption),
    );
    final response = await _rpcCall(serviceMessaging, 'SendMessage', payload);
    final date = _decodeSendMessageDate(response);
    final document = BaleFileDetails(
      fileId: details.fileId,
      accessHash: details.accessHash,
      name: details.name,
      size: details.size,
      mimeType: details.mimeType,
      caption: caption,
    );
    return BaleMessage(
      chat: peer,
      senderId: _session?.userId ?? 0,
      messageId: rid,
      date: date,
      document: document,
    );
  }

  Future<BaleFileUploadInfo> getFileUploadUrl({
    required int size,
    required String name,
    required String mimeType,
    BalePeer? peer,
    BaleSendType sendType = BaleSendType.document,
  }) async {
    final writer = ProtoWriter()
        .int64(1, size)
        .int32(3, _requireSession().userId ?? 0)
        .string(4, name)
        .string(5, mimeType);
    if (peer != null) {
      writer.bytes(6, _buildChat(peer));
      writer.bytes(7, ProtoWriter().int32(1, sendType.value).build());
    }
    final response = await _rpcCall(
      serviceFiles,
      'GetNasimFileUploadUrl',
      writer.build(),
    );
    return _decodeFileUploadInfo(response);
  }

  Future<BaleFileUrl?> getFileUrl({
    required int fileId,
    required int accessHash,
  }) async {
    final fileInfo = ProtoWriter()
        .int64(1, fileId)
        .int64(2, accessHash)
        .bytes(3, ProtoWriter().int32(1, 1).build())
        .build();
    final response = await _rpcCall(
      serviceFiles,
      'GetNasimFileUrl',
      ProtoWriter().bytes(1, fileInfo).build(),
    );
    return _decodeFileUrlResponse(response);
  }

  Future<List<int>> downloadFile({
    required int fileId,
    required int accessHash,
    void Function(List<int> chunk)? onChunk,
  }) async {
    final info = await getFileUrl(fileId: fileId, accessHash: accessHash);
    if (info == null) throw const BaleException('File URL not found');
    final client = HttpClient();
    final uri = Uri.parse(info.url);
    final watch = Stopwatch()..start();
    try {
      final request = await client.getUrl(uri);
      applyBaleRawDownloadHeaders(request);
      final response = await request.close();
      if (response.statusCode >= 400) {
        final body = await utf8.decodeStream(response);
        throw BaleHttpException(
          'Download failed with HTTP ${response.statusCode}: $body',
          stage: 'download',
          statusCode: response.statusCode,
          host: uri.host,
          elapsed: watch.elapsed,
          body: body,
          headers: _diagnosticHeaders(response.headers),
        );
      }
      final out = BytesBuilder(copy: false);
      await for (final chunk in response) {
        out.add(chunk);
        onChunk?.call(chunk);
      }
      return out.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    await disconnect();
    await _updates.close();
    if (_ownsHttpClient) _http.close();
  }

  Future<Uint8List> _authWithErrorMapping(
    Future<Uint8List> Function() operation,
  ) async {
    try {
      return await operation();
    } on GrpcWebException catch (error) {
      final message = error.message;
      throw BaleAuthException(
        message,
        _mapAuthError(message),
        code: error.status,
      );
    }
  }

  BaleAuthError _mapAuthError(String message) {
    if (message.contains('PHONE_CODE_INVALID')) return BaleAuthError.wrongCode;
    if (message.contains('password needed for login')) {
      return BaleAuthError.passwordNeeded;
    }
    if (message.contains('PHONE_NUMBER_UNOCCUPIED')) {
      return BaleAuthError.signUpNeeded;
    }
    if (message.contains('wrong password')) return BaleAuthError.wrongPassword;
    if (message.contains('phone auth limit exceeded')) {
      return BaleAuthError.rateLimit;
    }
    if (message.contains('PHONE_NUMBER_INVALID')) return BaleAuthError.invalid;
    if (message.contains('blocked')) return BaleAuthError.numberBanned;
    return BaleAuthError.unknown;
  }

  Future<BaleSession> _saveAuthResponse(Uint8List bytes) async {
    final response = _decodeAuthResponse(bytes);
    if (response.jwt.isEmpty) throw const BaleException('No JWT in response');
    final accessToken = await _fetchAccessToken(response.jwt) ?? response.jwt;
    final session = sessionFromJwt(accessToken: accessToken, jwt: response.jwt);
    _session = session;
    await credentialsStore.write(session);
    return session;
  }

  Future<Uint8List> _grpcCall(
    String service,
    String method,
    List<int> payload, {
    String? token,
  }) async {
    final url = _grpcBaseUri.replace(path: '/$service/$method');
    final response = await _http.post(
      url,
      headers: {
        'Content-Type': 'application/grpc-web+proto',
        'X-Grpc-Web': '1',
        'Origin': baleOrigin,
        if (token != null) 'Cookie': 'access_token=$token',
      },
      body: grpcWebEncode(payload),
    );
    return grpcWebDecode(response.bodyBytes);
  }

  Future<String?> _fetchAccessToken(String jwt) async {
    final response = await _http.get(
      _grpcBaseUri.replace(path: '/set-cookie/'),
      headers: {'Authorization': 'Bearer $jwt'},
    );
    for (final cookie
        in response.headersSplitValues['set-cookie'] ?? const []) {
      final match = RegExp(r'access_token=([^;]+)').firstMatch(cookie);
      if (match != null) return match.group(1);
    }
    return null;
  }

  Uint8List _buildStartPhoneAuth(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
    final deviceHash = List<int>.generate(16, (_) => _random.nextInt(256));
    return ProtoWriter()
        .int64(1, int.parse(digits))
        .int32(2, baleAuthAppId)
        .string(3, baleAuthApiKey)
        .bytes(4, deviceHash)
        .string(5, 'Bale Web')
        .string(7, 'fa')
        .int32(9, baleSendCodeSms)
        .build();
  }

  Uint8List _buildLoadUsersRequest(List<BaleUserPeerRef> peers) {
    final writer = ProtoWriter();
    for (final peer in peers) {
      writer.bytes(
        1,
        ProtoWriter().int32(1, peer.uid).int64(2, peer.accessHash).build(),
      );
    }
    return writer.build();
  }

  PhoneAuthResponse _decodeStartPhoneAuth(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var hash = '';
    var registered = false;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          hash = reader.string();
        case 2:
          registered = reader.varint() != 0;
        default:
          reader.skip(wire);
      }
    }
    return PhoneAuthResponse(transactionHash: hash, isRegistered: registered);
  }

  ValidateCodeResponse _decodeAuthResponse(List<int> bytes) {
    final reader = ProtoReader(bytes);
    String? jwt;
    Uint8List? user;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 2:
          user = reader.bytes();
        case 4:
          jwt = decodeWrappedString(reader.bytes());
        default:
          reader.skip(wire);
      }
    }
    return ValidateCodeResponse(jwt: jwt ?? '', userBytes: user);
  }

  _ContactsResponse _decodeGetContactsResponse(List<int> bytes) {
    final reader = ProtoReader(bytes);
    final users = <BaleUser>[];
    final peers = <BaleUserPeerRef>[];
    var isNotChanged = false;

    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          users.add(_decodeUserEntity(reader.bytes()));
        case 2:
          isNotChanged = reader.varint() != 0;
        case 3:
          peers.add(_decodeUserPeerRef(reader.bytes()));
        default:
          reader.skip(wire);
      }
    }

    return _ContactsResponse(
      inlineUsers: users,
      userPeers: peers,
      isNotChanged: isNotChanged,
    );
  }

  List<BaleUser> _decodeLoadUsersResponse(List<int> bytes) {
    final reader = ProtoReader(bytes);
    final users = <BaleUser>[];
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      if (field == 1) {
        users.add(_decodeUserEntity(reader.bytes()));
      } else {
        reader.skip(wire);
      }
    }
    return users;
  }

  BaleUserPeerRef _decodeUserPeerRef(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var uid = 0;
    var accessHash = 0;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          uid = reader.varint();
        case 2:
          accessHash = reader.varint();
        default:
          reader.skip(wire);
      }
    }
    return BaleUserPeerRef(uid: uid, accessHash: accessHash);
  }

  BaleUser _decodeUserEntity(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var id = 0;
    var accessHash = 0;
    var name = '';
    var nick = '';
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          id = reader.varint();
        case 2:
          accessHash = reader.varint();
        case 3:
          name = reader.string();
        case 9:
          nick = decodeWrappedString(reader.bytes()) ?? '';
        default:
          reader.skip(wire);
      }
    }
    return BaleUser(id: id, name: name, nick: nick, accessHash: accessHash);
  }

  BaleSession _requireSession() {
    final session = _session;
    if (session == null || session.accessToken.isEmpty) {
      throw const BaleException('No Bale session is available');
    }
    return session;
  }

  void _handleSocketMessage(dynamic message) {
    _lastInboundAt = DateTime.now();
    final bytes = message is Uint8List
        ? message
        : message is List<int>
        ? Uint8List.fromList(message)
        : Uint8List.fromList(utf8.encode(message.toString()));
    final frame = _decodeServerFrame(bytes);
    _handleFrame(frame);
  }

  void _handleFrame(_ServerFrame frame) {
    final handshake = frame.handshake;
    if (handshake != null) {
      if (handshake.protoVersion == baleProtoVersion &&
          handshake.apiVersion == baleApiVersion) {
        _ready = true;
        _reconnectAttempt = 0;
        _emitState(BaleConnectionState.ready);
        final connectCompleter = _connectCompleter;
        _connectCompleter = null;
        if (connectCompleter != null && !connectCompleter.isCompleted) {
          connectCompleter.complete();
        }
        _subscribe();
        _startPing();
        _startPresence();
      } else {
        _emitState(BaleConnectionState.versionMismatch);
        final connectCompleter = _connectCompleter;
        _connectCompleter = null;
        if (connectCompleter != null && !connectCompleter.isCompleted) {
          connectCompleter.completeError(
            BaleException(
              'Bale version mismatch: proto=${handshake.protoVersion}, '
              'api=${handshake.apiVersion}',
            ),
          );
        }
        unawaited(disconnect());
      }
    }

    final response = frame.response;
    if (response != null) {
      final pending = _pending.remove(response.index);
      if (pending != null) {
        pending.timer.cancel();
        if (response.error != null) {
          final error = _decodeRpcError(response.error!);
          pending.completer.completeError(error);
        } else {
          pending.completer.complete(response.payload ?? Uint8List(0));
        }
      } else if (response.index == _subscribeId &&
          (response.error != null || response.payload == null)) {
        final error = response.error == null
            ? null
            : _decodeRpcError(response.error!);
        final routine =
            error == null ||
            error.code == 4 ||
            (error.code == 2 && error.message.contains('want <EOF>'));
        if (!routine) {
          Future<void>.delayed(const Duration(seconds: 1), _subscribe);
        }
      } else if (response.payload != null) {
        _handleSubscribeResponse(response.payload!);
      }
    }

    final update = frame.update;
    if (update != null) _handleSubscribeResponse(update);
  }

  void _handleSubscribeResponse(List<int> bytes) {
    final reader = ProtoReader(bytes);
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          _handleUpdateUnion(reader.bytes());
        default:
          reader.skip(wire);
      }
    }
  }

  void _handleUpdateUnion(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var emitted = false;
    final fields = <String, Object?>{};
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      fields[field.toString()] = _updateFieldName(field);
      switch (field) {
        case 4:
          _updates.add(
            BaleMessageSentUpdate(_decodeInfoMessage(reader.bytes())),
          );
          emitted = true;
        case 55:
          final message = _decodeMessageUpdate(reader.bytes());
          if (message != null) {
            _updates.add(BaleMessageUpdate(message));
            emitted = true;
          }
        default:
          reader.skip(wire);
      }
    }
    if (!emitted) {
      _updates.add(BaleRawUpdate(Uint8List.fromList(bytes), fields: fields));
    }
  }

  List<BaleMessage> _decodeHistoryResponse(List<int> bytes, BalePeer chat) {
    final reader = ProtoReader(bytes);
    final messages = <BaleMessage>[];
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      if (field == 1) {
        final message = _decodeMessageData(reader.bytes(), chat);
        if (message != null) messages.add(message);
      } else {
        reader.skip(wire);
      }
    }
    return messages;
  }

  BaleMessage? _decodeMessageData(List<int> bytes, BalePeer chat) {
    final reader = ProtoReader(bytes);
    var senderId = 0;
    var messageId = 0;
    var date = 0;
    String? text;
    BaleFileDetails? document;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          senderId = reader.varint();
        case 2:
          messageId = reader.varint();
        case 3:
          date = reader.varint();
        case 4:
          final content = _decodeMessageContent(reader.bytes());
          text = content.text;
          document = content.document;
        default:
          reader.skip(wire);
      }
    }
    if (text == null && document == null) return null;
    return BaleMessage(
      chat: chat,
      senderId: senderId,
      messageId: messageId,
      date: date,
      text: text,
      document: document,
    );
  }

  BaleMessage? _decodeMessageUpdate(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var senderId = 0;
    var date = 0;
    var rid = 0;
    String? text;
    BaleFileDetails? document;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 2:
          senderId = reader.varint();
        case 3:
          date = reader.varint();
        case 4:
          rid = reader.varint();
        case 5:
          final content = _decodeMessageContent(reader.bytes());
          text = content.text;
          document = content.document;
        default:
          reader.skip(wire);
      }
    }
    if (text == null && document == null) return null;
    return BaleMessage(
      chat: const BalePeer.private(0),
      senderId: senderId,
      messageId: rid,
      date: date,
      text: text,
      document: document,
    );
  }

  _DecodedContent _decodeMessageContent(List<int> bytes) {
    final reader = ProtoReader(bytes);
    String? text;
    BaleFileDetails? document;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 4:
          document = _decodeDocumentMessage(reader.bytes());
        case 7:
          document = _decodeDocumentMessage(reader.bytes());
        case 15:
          text = _decodeTextMessage(reader.bytes());
        default:
          reader.skip(wire);
      }
    }
    return _DecodedContent(text: text, document: document);
  }

  String? _decodeTextMessage(List<int> bytes) {
    final reader = ProtoReader(bytes);
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      if (field == 1) return reader.string();
      reader.skip(wire);
    }
    return null;
  }

  BaleFileDetails _decodeDocumentMessage(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var fileId = 0;
    var accessHash = 0;
    var size = 0;
    var name = '';
    var mimeType = 'application/octet-stream';
    String? caption;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          fileId = reader.varint();
        case 2:
          accessHash = reader.varint();
        case 3:
          size = reader.varint();
        case 4:
          name = reader.string();
        case 5:
          mimeType = reader.string();
        case 8:
          caption = _decodeCaption(reader.bytes());
        default:
          reader.skip(wire);
      }
    }
    return BaleFileDetails(
      fileId: fileId,
      accessHash: accessHash,
      name: name,
      size: size,
      mimeType: mimeType,
      caption: caption,
    );
  }

  String? _decodeCaption(List<int> bytes) {
    final reader = ProtoReader(bytes);
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      if (field == 1) return reader.string();
      reader.skip(wire);
    }
    return null;
  }

  BaleInfoMessage _decodeInfoMessage(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var peer = const BalePeer.private(0);
    var messageId = 0;
    var date = 0;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          peer = _decodePeer(reader.bytes());
        case 2:
          messageId = reader.varint();
        case 3:
          if (wire == 2) {
            date = decodeWrappedInt(reader.bytes()) ?? 0;
          } else {
            date = reader.varint();
          }
        default:
          reader.skip(wire);
      }
    }
    return BaleInfoMessage(peer: peer, messageId: messageId, date: date);
  }

  BalePeer _decodePeer(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var type = BalePeerType.private;
    var id = 0;
    int? accessHash;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          type = _peerTypeFromValue(reader.varint());
        case 2:
          id = reader.varint();
        case 3:
          accessHash = reader.varint();
        default:
          reader.skip(wire);
      }
    }
    return BalePeer(id: id, type: type, accessHash: accessHash);
  }

  BalePeerType _peerTypeFromValue(int value) {
    for (final type in BalePeerType.values) {
      if (type.value == value) return type;
    }
    return BalePeerType.unknown;
  }

  String _updateFieldName(int field) => switch (field) {
    4 => 'messageSent',
    19 => 'messageRead',
    46 => 'messageDeleted',
    47 => 'chatCleared',
    48 => 'chatDeleted',
    50 => 'messageReadByMe',
    55 => 'newMessage',
    85 => 'emptyUpdate',
    162 => 'messageEdited',
    209 => 'usernameChanged',
    210 => 'aboutChanged',
    721 => 'groupMessagePinned',
    722 => 'groupPinRemoved',
    2629 => 'userBlocked',
    2630 => 'userUnblocked',
    _ => 'field=$field',
  };

  Future<Uint8List> _rpcCall(
    String service,
    String method,
    List<int> payload,
  ) async {
    if (!_ready || _socket == null) {
      throw const BaleException('Not connected to Bale');
    }
    final index = ++_requestId;
    final completer = Completer<Uint8List>();
    final timer = Timer(const Duration(seconds: 30), () {
      _pending.remove(index);
      if (!completer.isCompleted) {
        completer.completeError(const BaleException('RPC timed out'));
      }
    });
    _pending[index] = _PendingRpc(completer, timer);
    _socket!.add(_encodeRpc(service, method, payload, index));
    return completer.future;
  }

  void _subscribe() {
    if (!_ready || _socket == null) return;
    _subscribeId = ++_requestId;
    _socket!.add(
      _encodeRpc(
        serviceMavizStream,
        'SubscribeToUpdates',
        Uint8List(0),
        _subscribeId,
      ),
    );
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_ready || _socket == null) return;
      final last = _lastInboundAt;
      if (last != null && DateTime.now().difference(last).inSeconds > 30) {
        unawaited(_socket!.close());
        return;
      }
      _socket!.add(_encodePing(++_pingId));
    });
  }

  void _startPresence() {
    _presenceTimer?.cancel();
    final payload = ProtoWriter().int32(1, 1).int64(2, 90000).build();
    void send() {
      if (_ready) {
        unawaited(
          _rpcCall(
            servicePresence,
            'SetOnline',
            payload,
          ).catchError((_) => Uint8List(0)),
        );
      }
    }

    send();
    _presenceTimer = Timer.periodic(const Duration(seconds: 90), (_) => send());
  }

  void _handleSocketClosed() {
    final code = _socket?.closeCode;
    _ready = false;
    _pingTimer?.cancel();
    _presenceTimer?.cancel();
    final connectCompleter = _connectCompleter;
    _connectCompleter = null;
    if (connectCompleter != null && !connectCompleter.isCompleted) {
      connectCompleter.completeError(
        BaleException('WebSocket closed${code == null ? '' : ' ($code)'}'),
      );
    }
    _drainPending(
      BaleException('WebSocket closed${code == null ? '' : ' ($code)'}'),
    );
    _socket = null;

    if (_closedByUser) return;
    if (code == 4401) {
      _emitState(BaleConnectionState.tokenExpired);
      _session = null;
      unawaited(credentialsStore.clear());
      return;
    }

    final delay = Duration(
      seconds: min(30, 3 * (1 << min(_reconnectAttempt++, 4))),
    );
    _emitState(BaleConnectionState.reconnecting);
    _reconnectTimer = Timer(delay, () {
      if (!_closedByUser && _session != null) {
        unawaited(connect().catchError((_) {}));
      }
    });
  }

  void _drainPending(Object error) {
    for (final pending in _pending.values) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pending.clear();
  }

  void _emitState(BaleConnectionState state) {
    if (!_updates.isClosed) _updates.add(BaleConnectionStateUpdate(state));
  }

  Uint8List _encodeHandshake() {
    final body = ProtoWriter()
        .int32(1, baleProtoVersion)
        .int64(2, baleApiVersion)
        .build();
    return ProtoWriter().bytes(3, body).build();
  }

  Uint8List _encodePing(int id) {
    final body = ProtoWriter().int64(1, id).build();
    return ProtoWriter().bytes(2, body).build();
  }

  Uint8List _encodeRpc(
    String service,
    String method,
    List<int> payload,
    int index,
  ) {
    final body = ProtoWriter().string(1, service).string(2, method);
    if (payload.isNotEmpty) body.bytes(3, payload);
    body.int64(5, index);
    return ProtoWriter().bytes(1, body.build()).build();
  }

  Uint8List _buildSendMessage(BalePeer peer, int rid, List<int> content) {
    return ProtoWriter()
        .bytes(1, _buildPeer(peer))
        .int64(2, rid)
        .bytes(3, content)
        .bytes(6, _buildPeer(peer))
        .build();
  }

  Uint8List _buildTextContent(String text) {
    final textMessage = ProtoWriter().string(1, text).build();
    return ProtoWriter().bytes(15, textMessage).build();
  }

  Uint8List _buildDocumentContent(BaleFileDetails details, String? caption) {
    final document = ProtoWriter()
        .int64(1, details.fileId)
        .int64(2, details.accessHash)
        .int32(3, details.size)
        .string(4, details.name)
        .string(5, details.mimeType);
    if (caption != null && caption.isNotEmpty) {
      document.bytes(8, ProtoWriter().string(1, caption).build());
    }
    return ProtoWriter().bytes(4, document.build()).build();
  }

  Uint8List _buildPeer(BalePeer peer) {
    final writer = ProtoWriter().int32(1, peer.type.value).int32(2, peer.id);
    if (peer.accessHash != null) writer.int64(3, peer.accessHash!);
    return writer.build();
  }

  Uint8List _buildChat(BalePeer peer) {
    final chatType = peer.type == BalePeerType.group
        ? BaleChatType.group.value
        : BaleChatType.private.value;
    return ProtoWriter().int32(1, chatType).int32(2, peer.id).build();
  }

  int _decodeSendMessageDate(List<int> bytes) {
    final reader = ProtoReader(bytes);
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      if (field == 2) return reader.varint();
      reader.skip(wire);
    }
    return DateTime.now().millisecondsSinceEpoch;
  }

  BaleFileUploadInfo _decodeFileUploadInfo(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var fileId = 0;
    var url = '';
    var chunkSize = 262144;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          fileId = reader.varint();
        case 2:
          url = reader.string();
        case 4:
          chunkSize = reader.varint();
        default:
          reader.skip(wire);
      }
    }
    return BaleFileUploadInfo(fileId: fileId, url: url, chunkSize: chunkSize);
  }

  BaleFileUrl? _decodeFileUrlResponse(List<int> bytes) {
    final reader = ProtoReader(bytes);
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      if (field == 1) return _decodeFileUrl(reader.bytes());
      reader.skip(wire);
    }
    return null;
  }

  BaleFileUrl _decodeFileUrl(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var fileId = 0;
    var url = '';
    var timeout = 0;
    var chunkSize = 65536;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          fileId = reader.varint();
        case 2:
          url = reader.string();
        case 3:
          timeout = reader.varint();
        case 7:
          if (wire == 2) {
            chunkSize = decodeWrappedInt(reader.bytes()) ?? chunkSize;
          } else {
            chunkSize = reader.varint();
          }
        default:
          reader.skip(wire);
      }
    }
    return BaleFileUrl(
      fileId: fileId,
      url: url,
      timeout: timeout,
      chunkSize: chunkSize,
    );
  }

  Future<void> _upload(
    BaleFileInput file,
    BaleFileUploadInfo upload,
    int total,
    void Function(int sent, int total)? onProgress,
  ) async {
    final client = HttpClient();
    final uri = Uri.parse(upload.url);
    final watch = Stopwatch()..start();
    var sent = 0;
    try {
      final request = await client
          .putUrl(uri)
          .timeout(const Duration(minutes: 5));
      applyBaleRawUploadHeaders(
        request,
        accessToken: _requireSession().accessToken,
      );
      request.contentLength = total;
      await for (final chunk in file.openRead(upload.chunkSize)) {
        sent += chunk.length;
        request.add(chunk);
        onProgress?.call(sent, total);
      }
      final response = await request.close().timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          request.abort();
          throw const BaleException('Upload timed out waiting for Bale');
        },
      );
      if (response.statusCode >= 400) {
        final body = await utf8.decodeStream(response);
        throw BaleHttpException(
          'Upload failed with HTTP ${response.statusCode}: $body',
          stage: 'upload',
          statusCode: response.statusCode,
          host: uri.host,
          elapsed: watch.elapsed,
          body: body,
          headers: _diagnosticHeaders(response.headers),
        );
      }
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
  }

  _ServerFrame _decodeServerFrame(List<int> bytes) {
    final reader = ProtoReader(bytes);
    final frame = _ServerFrame();
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          frame.response = _decodeRpcResponse(reader.bytes());
        case 2:
          frame.update = _decodeUpdateContainer(reader.bytes());
        case 3:
          frame.terminateSession = true;
          reader.skip(wire);
        case 4:
          reader.bytes();
        case 5:
          frame.handshake = _decodeHandshakeResponse(reader.bytes());
        default:
          reader.skip(wire);
      }
    }
    return frame;
  }

  _HandshakeResponse _decodeHandshakeResponse(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var proto = 0;
    var api = 0;
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          proto = reader.varint();
        case 2:
          api = reader.varint();
        default:
          reader.skip(wire);
      }
    }
    return _HandshakeResponse(proto, api);
  }

  Uint8List _decodeUpdateContainer(List<int> bytes) {
    final reader = ProtoReader(bytes);
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      if (field == 1) return reader.bytes();
      reader.skip(wire);
    }
    return Uint8List(0);
  }

  _RpcResponse _decodeRpcResponse(List<int> bytes) {
    final reader = ProtoReader(bytes);
    final response = _RpcResponse();
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          response.error = reader.bytes();
        case 2:
          response.payload = reader.bytes();
        case 3:
          response.index = reader.varint();
        default:
          reader.skip(wire);
      }
    }
    return response;
  }

  BaleException _decodeRpcError(List<int> bytes) {
    final reader = ProtoReader(bytes);
    var code = 0;
    var message = '';
    while (reader.hasMore) {
      final (field, wire) = reader.tag();
      switch (field) {
        case 1:
          code = reader.varint();
        case 2:
          message = reader.string();
        default:
          reader.skip(wire);
      }
    }
    return BaleException(message.isEmpty ? 'RPC error' : message, code: code);
  }
}

http.StreamedRequest buildBaleRawUploadRequest({
  required Uri uploadUrl,
  required String accessToken,
  required String mimeType,
  required int contentLength,
}) {
  return http.StreamedRequest('PUT', uploadUrl)
    ..headers['Origin'] = baleOrigin
    ..headers['Cookie'] = 'access_token=$accessToken'
    ..headers['User-Agent'] = baleBrowserUserAgent
    ..headers['Accept'] = '*/*'
    ..headers['Content-Type'] = 'multipart/form-data'
    ..contentLength = contentLength;
}

http.Request buildBaleRawDownloadRequest({required Uri downloadUrl}) {
  return http.Request('GET', downloadUrl)
    ..headers['Origin'] = baleOrigin
    ..headers['User-Agent'] = baleBrowserUserAgent
    ..headers['Accept'] = '*/*';
}

void applyBaleRawUploadHeaders(
  HttpClientRequest request, {
  required String accessToken,
}) {
  request.headers
    ..set('Origin', baleOrigin)
    ..set(HttpHeaders.cookieHeader, 'access_token=$accessToken')
    ..set(HttpHeaders.userAgentHeader, baleBrowserUserAgent)
    ..set(HttpHeaders.acceptHeader, '*/*')
    ..set(HttpHeaders.contentTypeHeader, 'multipart/form-data');
}

void applyBaleRawDownloadHeaders(HttpClientRequest request) {
  request.headers
    ..set('Origin', baleOrigin)
    ..set(HttpHeaders.userAgentHeader, baleBrowserUserAgent)
    ..set(HttpHeaders.acceptHeader, '*/*');
}

Map<String, String> _diagnosticHeaders(HttpHeaders headers) {
  const names = [
    'retry-after',
    'server',
    'date',
    'x-request-id',
    'x-amzn-requestid',
    'x-cache',
    'cf-ray',
  ];
  return {for (final name in names) name: ?headers.value(name)};
}

class _PendingRpc {
  const _PendingRpc(this.completer, this.timer);

  final Completer<Uint8List> completer;
  final Timer timer;
}

class _ServerFrame {
  _RpcResponse? response;
  Uint8List? update;
  _HandshakeResponse? handshake;
  bool terminateSession = false;
}

class _RpcResponse {
  int index = 0;
  Uint8List? error;
  Uint8List? payload;
}

class _HandshakeResponse {
  const _HandshakeResponse(this.protoVersion, this.apiVersion);

  final int protoVersion;
  final int apiVersion;
}

class _DecodedContent {
  const _DecodedContent({this.text, this.document});

  final String? text;
  final BaleFileDetails? document;
}

class BaleUserPeerRef {
  const BaleUserPeerRef({required this.uid, required this.accessHash});

  final int uid;
  final int accessHash;
}

class _ContactsResponse {
  const _ContactsResponse({
    required this.inlineUsers,
    required this.userPeers,
    required this.isNotChanged,
  });

  final List<BaleUser> inlineUsers;
  final List<BaleUserPeerRef> userPeers;
  final bool isNotChanged;
}
