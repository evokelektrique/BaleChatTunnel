import 'dart:async';
import 'dart:io';

import 'package:bale_client/bale_client.dart';

Future<void> main(List<String> args) async {
  final cli = _Cli(args);
  await cli.run();
}

class _Cli {
  _Cli(this.args);

  final List<String> args;

  late final BaleClient client = BaleClient(
    credentialsStore: FileBaleCredentialsStore(_sessionPath),
  );

  String get _sessionPath {
    final env = Platform.environment['BALE_SESSION'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    return 'session.bale_client.json';
  }

  Future<void> run() async {
    final command = args.isEmpty ? 'help' : args.first;
    try {
      switch (command) {
        case 'login':
          await _login();
        case 'listen':
          await _connect();
          await _listenForever();
        case 'peers':
          await _peers();
        case 'send':
          await _send();
        case 'send-file':
          await _sendFile();
        case 'download':
          await _download();
        case 'logout':
          await _logout();
        case 'status':
          await _status();
        default:
          _printHelp();
      }
    } on BaleAuthException catch (error) {
      stderr.writeln('Auth failed: ${error.authError.name}: ${error.message}');
      exitCode = 2;
    } on Object catch (error) {
      stderr.writeln('Error: $error');
      exitCode = 1;
    } finally {
      if (command != 'listen') await client.close();
    }
  }

  Future<void> _login() async {
    stdout.write('Phone number (+98912...): ');
    final phone = stdin.readLineSync()?.trim();
    if (phone == null || phone.isEmpty) throw Exception('phone is required');

    final started = await client.startPhoneAuth(phone);
    stdout.writeln('Code sent. registered=${started.isRegistered}');

    stdout.write('Code: ');
    final code = stdin.readLineSync()?.trim();
    if (code == null || code.isEmpty) throw Exception('code is required');

    try {
      await client.validateCode(
        transactionHash: started.transactionHash,
        code: code,
      );
    } on BaleAuthException catch (error) {
      if (error.authError == BaleAuthError.passwordNeeded) {
        stdout.write('Two-factor password: ');
        final password = stdin.readLineSync()?.trim();
        if (password == null || password.isEmpty) {
          throw Exception('password is required');
        }
        await client.validatePassword(
          transactionHash: started.transactionHash,
          password: password,
        );
      } else if (error.authError == BaleAuthError.signUpNeeded) {
        stdout.write('New account name: ');
        final name = stdin.readLineSync()?.trim();
        if (name == null || name.isEmpty) throw Exception('name is required');
        await client.signUp(
          transactionHash: started.transactionHash,
          name: name,
        );
      } else {
        rethrow;
      }
    }

    final session = client.session;
    stdout.writeln('Logged in as userId=${session?.userId ?? 'unknown'}');
    stdout.writeln('Session stored at $_sessionPath');
  }

  Future<void> _connect() async {
    final session = await client.restoreSession();
    if (session == null) {
      throw Exception('no saved session; run login first');
    }
    await client.connect();
  }

  Future<void> _listenForever() async {
    stdout.writeln('Listening. Press Ctrl+C to exit.');
    client.updates.listen((update) {
      switch (update) {
        case BaleConnectionStateUpdate(:final state):
          stdout.writeln('[state] ${state.name}');
        case BaleMessageUpdate(:final message):
          _printMessage(message);
        case BaleMessageSentUpdate(:final info):
          unawaited(_printSentMessage(info));
        case BaleRawUpdate(:final fields, :final bytes):
          final names = fields.values.join(',');
          stdout.writeln(
            '[update] ${names.isEmpty ? 'unknown' : names} bytes=${bytes.length}',
          );
      }
    });
    await Completer<void>().future;
  }

  Future<void> _printSentMessage(BaleInfoMessage info) async {
    stdout.writeln(
      '[sent] peer=${info.peer.type.name}:${info.peer.id} '
      'messageId=${info.messageId} date=${info.date}',
    );
    try {
      final history = await client.loadHistory(peer: info.peer, limit: 10);
      BaleMessage? message;
      for (final item in history) {
        if (item.messageId == info.messageId) {
          message = item;
          break;
        }
      }
      if (message != null) {
        _printMessage(message, prefix: 'sent ');
      }
    } on Object catch (error) {
      stdout.writeln('[sent] history lookup failed: $error');
    }
  }

  void _printMessage(BaleMessage message, {String prefix = ''}) {
    final document = message.document;
    if (document != null) {
      stdout.writeln(
        '[${prefix}file] from=${message.senderId} messageId=${message.messageId} '
        'name="${document.name}" size=${document.size} '
        'mime=${document.mimeType} fileId=${document.fileId} '
        'accessHash=${document.accessHash}',
      );
      if (document.caption != null && document.caption!.isNotEmpty) {
        stdout.writeln('[caption] ${document.caption}');
      }
      return;
    }

    if (message.text != null) {
      stdout.writeln(
        '[${prefix}message] from=${message.senderId} messageId=${message.messageId} '
        '${message.text}',
      );
      return;
    }

    stdout.writeln(
      '[${prefix}message] from=${message.senderId} messageId=${message.messageId} <non-text>',
    );
  }

  Future<void> _send() async {
    if (args.length < 3) {
      throw Exception('usage: send <private|group> <peer-id> <text...>');
    }
    await _connect();
    final peer = _peer(args[1], args[2]);
    final text = args.skip(3).join(' ');
    if (text.isEmpty) throw Exception('text is required');
    final message = await client.sendText(peer: peer, text: text);
    stdout.writeln('Sent message ${message.messageId}');
  }

  Future<void> _peers() async {
    final session = await client.restoreSession();
    if (session == null) {
      throw Exception('no saved session; run login first');
    }
    final contacts = await client.getContacts();
    if (contacts.isEmpty) {
      stdout.writeln('No contacts returned.');
      return;
    }
    for (final user in contacts) {
      final nick = user.nick.isEmpty ? '' : ' @${user.nick}';
      final hash = user.accessHash == 0 ? '' : ' accessHash=${user.accessHash}';
      stdout.writeln('${user.id}\t${user.displayName}$nick$hash');
    }
  }

  Future<void> _sendFile() async {
    if (args.length < 4) {
      throw Exception(
        'usage: send-file <private|group> <peer-id> <path> [caption...]',
      );
    }
    await _connect();
    final peer = _peer(args[1], args[2]);
    final path = args[3];
    final caption = args.length > 4 ? args.skip(4).join(' ') : null;
    final message = await client.sendDocument(
      peer: peer,
      file: BaleFileInput.path(path),
      caption: caption,
      onProgress: (sent, total) {
        stdout.write('\rUploading $sent/$total bytes');
      },
    );
    final document = message.document;
    stdout.writeln('\nSent file message ${message.messageId}');
    if (document != null) {
      stdout.writeln(
        'fileId=${document.fileId} accessHash=${document.accessHash} '
        'name="${document.name}"',
      );
    }
  }

  Future<void> _download() async {
    if (args.length != 4) {
      throw Exception('usage: download <file-id> <access-hash> <output-path>');
    }
    await _connect();
    final fileId = int.parse(args[1]);
    final accessHash = int.parse(args[2]);
    final output = File(args[3]);
    final bytes = await client.downloadFile(
      fileId: fileId,
      accessHash: accessHash,
      onChunk: (chunk) =>
          stdout.write('\rDownloaded ${chunk.length} byte chunk'),
    );
    await output.writeAsBytes(bytes);
    stdout.writeln('\nSaved ${bytes.length} bytes to ${output.path}');
  }

  Future<void> _logout() async {
    await client.restoreSession();
    await client.logout(remote: args.contains('--remote'));
    stdout.writeln('Logged out.');
  }

  Future<void> _status() async {
    final session = await client.restoreSession();
    if (session == null) {
      stdout.writeln('No saved session at $_sessionPath');
      return;
    }
    stdout.writeln('Session: $_sessionPath');
    stdout.writeln('userId: ${session.userId ?? 'unknown'}');
    stdout.writeln(
      'expiresAt: ${session.expiresAt?.toIso8601String() ?? 'unknown'}',
    );
    stdout.writeln('expired: ${session.isExpired}');
  }

  BalePeer _peer(String type, String idText) {
    final id = int.parse(idText);
    return switch (type) {
      'private' => BalePeer.private(id),
      'group' => BalePeer.group(id),
      _ => throw Exception('peer type must be private or group'),
    };
  }

  void _printHelp() {
    stdout.writeln('''
Bale client CLI

Usage:
  dart run bale_client:bale_client_cli login
  dart run bale_client:bale_client_cli status
  dart run bale_client:bale_client_cli peers
  dart run bale_client:bale_client_cli listen
  dart run bale_client:bale_client_cli send <private|group> <peer-id> <text...>
  dart run bale_client:bale_client_cli send-file <private|group> <peer-id> <path> [caption...]
  dart run bale_client:bale_client_cli download <file-id> <access-hash> <output-path>
  dart run bale_client:bale_client_cli logout [--remote]

Environment:
  BALE_SESSION=/path/to/session.json
''');
  }
}
