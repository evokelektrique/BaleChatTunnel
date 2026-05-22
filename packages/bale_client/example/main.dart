// ignore_for_file: avoid_print

import 'dart:io';

import 'package:bale_client/bale_client.dart';

Future<void> main(List<String> args) async {
  final client = BaleClient(
    credentialsStore: FileBaleCredentialsStore('session.bale_client.json'),
  );

  final restored = await client.restoreSession(connect: false);
  if (restored == null) {
    stdout.write('Phone number: ');
    final phone = stdin.readLineSync()!.trim();
    final auth = await client.startPhoneAuth(phone);

    stdout.write('Code: ');
    final code = stdin.readLineSync()!.trim();
    await client.validateCode(
      transactionHash: auth.transactionHash,
      code: code,
    );
  }

  await client.connect();
  client.updates.listen((update) {
    if (update is BaleMessageUpdate) {
      print('message from ${update.message.senderId}: ${update.message.text}');
    }
  });

  if (args.length >= 2) {
    await client.sendText(
      peer: BalePeer.private(int.parse(args[0])),
      text: args.sublist(1).join(' '),
    );
  }
}
