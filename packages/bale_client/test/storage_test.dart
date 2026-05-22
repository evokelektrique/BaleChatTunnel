import 'dart:io';

import 'package:bale_client/bale_client.dart';
import 'package:test/test.dart';

void main() {
  test('file credential store persists sessions', () async {
    final dir = await Directory.systemTemp.createTemp('bale_client_test_');
    addTearDown(() => dir.delete(recursive: true));

    final store = FileBaleCredentialsStore('${dir.path}/session.json');
    final session = BaleSession(
      accessToken: 'access',
      jwt: 'jwt',
      userId: 123,
      authId: 'auth',
      authSid: 456,
      expiresAt: DateTime.utc(2030),
    );

    await store.write(session);
    final restored = await store.read();
    expect(restored?.accessToken, 'access');
    expect(restored?.userId, 123);
    expect(restored?.authSid, 456);

    await store.clear();
    expect(await store.read(), isNull);
  });
}
