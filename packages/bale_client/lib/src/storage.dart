import 'dart:convert';
import 'dart:io';

import 'models.dart';

abstract interface class BaleCredentialsStore {
  Future<BaleSession?> read();
  Future<void> write(BaleSession session);
  Future<void> clear();
}

class MemoryBaleCredentialsStore implements BaleCredentialsStore {
  BaleSession? _session;

  @override
  Future<void> clear() async {
    _session = null;
  }

  @override
  Future<BaleSession?> read() async => _session;

  @override
  Future<void> write(BaleSession session) async {
    _session = session;
  }
}

class FileBaleCredentialsStore implements BaleCredentialsStore {
  FileBaleCredentialsStore(String path) : file = File(path);

  final File file;

  @override
  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }

  @override
  Future<BaleSession?> read() async {
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid Bale credentials file');
    }
    return BaleSession.fromJson(decoded);
  }

  @override
  Future<void> write(BaleSession session) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
      mode: FileMode.write,
      flush: true,
    );
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', file.path]);
    }
  }
}
