import 'package:bale_client/src/bale_client.dart';
import 'package:test/test.dart';

void main() {
  test('raw upload request matches Bale streamed upload headers', () {
    final request = buildBaleRawUploadRequest(
      uploadUrl: Uri.parse('https://upload.example.test/file'),
      accessToken: 'token',
      mimeType: 'application/octet-stream',
      contentLength: 123,
    );

    expect(request.method, 'PUT');
    expect(request.headers['Origin'], isNotEmpty);
    expect(request.headers['Cookie'], 'access_token=token');
    expect(request.headers['User-Agent'], baleBrowserUserAgent);
    expect(request.headers['Accept'], '*/*');
    expect(request.headers['Content-Type'], 'multipart/form-data');
    expect(request.contentLength, 123);
  });

  test('raw download request matches Bale file stream headers', () {
    final request = buildBaleRawDownloadRequest(
      downloadUrl: Uri.parse('https://download.example.test/file'),
    );

    expect(request.method, 'GET');
    expect(request.headers['Origin'], isNotEmpty);
    expect(request.headers['User-Agent'], baleBrowserUserAgent);
    expect(request.headers['Accept'], '*/*');
    expect(request.headers.containsKey('Cookie'), isFalse);
  });
}
