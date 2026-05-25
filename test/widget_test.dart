import 'package:bale_chat_tunnel/btun.dart';
import 'package:bale_chat_tunnel/main.dart';
import 'package:bale_client/bale_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home is a clean connection screen', (tester) async {
    final controller = BtunAppController(persistPrefs: false)
      ..status = RuntimeStatus.idle;

    await tester.pumpWidget(BtunApp(controller: controller));

    expect(find.text('Connect'), findsNothing);
    expect(find.text('Disconnect'), findsNothing);
    expect(find.byIcon(Icons.power_settings_new_outlined), findsOneWidget);
    expect(find.text('Downloaded 0 B'), findsOneWidget);
    expect(find.text('Uploaded 0 B'), findsOneWidget);
    expect(find.text('Config'), findsOneWidget);
    expect(find.text('Bale'), findsOneWidget);
    expect(find.text('Relay key'), findsOneWidget);
    expect(find.text('Phone number'), findsNothing);
    expect(find.text('Login'), findsNothing);
    await tester.tap(find.byIcon(Icons.power_settings_new_outlined));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.error, isNull);
    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Phone number'), findsOneWidget);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Logs'), findsWidgets);
  });

  testWidgets('navigation order is home logs settings', (tester) async {
    final controller = BtunAppController(persistPrefs: false);

    await tester.pumpWidget(BtunApp(controller: controller));

    expect(BtunPage.values, [BtunPage.home, BtunPage.logs, BtunPage.settings]);
  });

  testWidgets('settings shows account action and theme controls', (
    tester,
  ) async {
    final controller = BtunAppController(persistPrefs: false)
      ..config = BtunConfig.defaults(profileDir: '.btun').copyWith(
        sessionId: 'client-a',
        localPublicKey: 'local-key',
        peerPublicKey: 'relay-key',
      );

    await tester.pumpWidget(BtunApp(controller: controller));
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();

    expect(find.text('Session name'), findsOneWidget);
    expect(find.text('client-a'), findsWidgets);
    expect(find.text('Profile directory'), findsOneWidget);
    expect(find.text('Initialize config'), findsNothing);
    expect(find.text('Add account'), findsOneWidget);
    expect(find.text('No accounts configured.'), findsOneWidget);
    controller.session = const BaleSession(accessToken: 'token', userId: 123);
    controller.accountSessions[123] = controller.session!;
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('Add account'), findsOneWidget);
    expect(find.text('Add account'), findsOneWidget);
    expect(find.text('Relay public key'), findsOneWidget);
    expect(find.text('Client public key'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Key Exchange'), findsNothing);

    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pump();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(controller.themeMode, ThemeMode.dark);
  });

  testWidgets('dismisses error banner', (tester) async {
    final controller = BtunAppController(persistPrefs: false)
      ..error = 'Something failed';

    await tester.pumpWidget(BtunApp(controller: controller));
    await tester.tap(find.text('Dismiss'));
    await tester.pump();

    expect(controller.error, isNull);
    expect(find.text('Something failed'), findsNothing);
  });

  testWidgets('home formats session traffic totals', (tester) async {
    final controller = BtunAppController(persistPrefs: false)
      ..status = RuntimeStatus.idle
      ..sessionDownloadedBytes = 12 * 1024 * 1024 + 410 * 1024
      ..sessionUploadedBytes = 8 * 1024 + 120;

    await tester.pumpWidget(BtunApp(controller: controller));

    expect(find.text('Downloaded 12.4 MB'), findsOneWidget);
    expect(find.text('Uploaded 8.1 KB'), findsOneWidget);
  });
}
