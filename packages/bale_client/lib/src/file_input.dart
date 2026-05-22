import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

class BaleFileInput {
  BaleFileInput.path(String path, {String? name, String? mimeType})
    : _file = File(path),
      _bytes = null,
      name = name ?? p.basename(path),
      mimeType = mimeType ?? lookupMimeType(path) ?? 'application/octet-stream';

  BaleFileInput.bytes(List<int> bytes, {required this.name, String? mimeType})
    : _file = null,
      _bytes = Uint8List.fromList(bytes),
      mimeType =
          mimeType ??
          lookupMimeType(name, headerBytes: bytes.take(32).toList()) ??
          'application/octet-stream';

  final File? _file;
  final Uint8List? _bytes;
  final String name;
  final String mimeType;

  Future<int> get size async => _bytes?.length ?? await _file!.length();

  Stream<List<int>> openRead([int chunkSize = 262144]) {
    final bytes = _bytes;
    if (bytes != null) {
      return Stream<List<int>>.fromIterable(_chunkBytes(bytes, chunkSize));
    }
    return _file!.openRead();
  }

  static Iterable<Uint8List> _chunkBytes(Uint8List bytes, int chunkSize) sync* {
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = offset + chunkSize > bytes.length
          ? bytes.length
          : offset + chunkSize;
      yield Uint8List.sublistView(bytes, offset, end);
    }
  }
}
