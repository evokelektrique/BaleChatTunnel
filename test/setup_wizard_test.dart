import 'dart:io';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('prompt parsing', () {
    test('accepts bool defaults and values', () {
      expect(parseBool('', defaultValue: true), isTrue);
      expect(parseBool('n', defaultValue: true), isFalse);
      expect(parseBool('yes', defaultValue: false), isTrue);
      expect(parseBool('false', defaultValue: true), isFalse);
      expect(
        () => parseBool('maybe', defaultValue: true),
        throwsFormatException,
      );
    });

    test('parses integers with default and range checks', () {
      expect(parseInt('', defaultValue: 7), 7);
      expect(parseInt('42', defaultValue: 7, min: 1, max: 100), 42);
      expect(
        () => parseInt('0', defaultValue: 7, min: 1),
        throwsFormatException,
      );
      expect(() => parseInt('wat', defaultValue: 7), throwsFormatException);
    });

    test('parses comma-separated port lists', () {
      expect(parsePortList('', defaultValue: [80, 443]), [80, 443]);
      expect(parsePortList('80,443, 8443', defaultValue: [1]), [80, 443, 8443]);
      expect(
        () => parsePortList('80,99999', defaultValue: [80]),
        throwsFormatException,
      );
    });

    test('? help repeats prompt and invalid input retries', () async {
      final output = StringBuffer();
      final wizard = _wizard(lines: ['?', 'later', 'yes'], output: output);

      final value = await wizard.promptBool(
        'Enable',
        defaultValue: false,
        help: 'Use yes or no.',
      );

      expect(value, isTrue);
      expect(output.toString(), contains('Use yes or no.'));
      expect(output.toString(), contains('Invalid input'));
      expect('Enable'.allMatches(output.toString()).length, 3);
    });

    test('transfer mode accepts numbered choices', () async {
      final output = StringBuffer();
      final wizard = _wizard(lines: ['2'], output: output);

      final value = await wizard.promptTransferMode(
        'Transfer mode',
        defaultValue: BtunTransferMode.balanced,
      );

      expect(value, BtunTransferMode.bulk);
      expect(output.toString(), contains('Transfer mode [1 balanced]:'));
    });
  });

  group('setup flow', () {
    test('new relay setup with defaults writes relay role', () async {
      final temp = await Directory.systemTemp.createTemp('btun_setup_test_');
      addTearDown(() => temp.delete(recursive: true));
      final output = StringBuffer();

      await _wizard(
        lines: _defaultSetupLines(login: 'no'),
        output: output,
        profile: temp.path,
      ).run();

      final config = await BtunConfig.load(
        BtunConfig.defaultConfigPath(temp.path),
      );
      expect(config.role, BtunRole.relay);
      expect(config.transferMode, BtunTransferMode.balanced);
      expect(config.localPublicKey, isNotEmpty);
      expect(config.peerPublicKey, '');
      expect(output.toString(), contains('relay_public_key:'));
      expect(output.toString(), contains('Missing Client public key.'));
      expect(output.toString(), contains('btun login --profile ${temp.path}'));
      expect(output.toString(), isNot(contains('Client SOCKS')));
      expect(output.toString(), isNot(contains('SOCKS host')));
      expect(output.toString(), isNot(contains('SOCKS port')));
    });

    test('existing config preserves local keys', () async {
      final temp = await Directory.systemTemp.createTemp('btun_setup_test_');
      addTearDown(() => temp.delete(recursive: true));
      final path = BtunConfig.defaultConfigPath(temp.path);
      await BtunConfig.defaults(profileDir: temp.path)
          .copyWith(
            localPublicKey: 'existing-public',
            localPrivateKey: 'existing-private',
            peerPublicKey: 'old-peer',
          )
          .save(path);

      await _wizard(
        lines: ['yes', '', '', '', '', '', '', 'no'],
        output: StringBuffer(),
        profile: temp.path,
      ).run();

      final config = await BtunConfig.load(path);
      expect(config.localPublicKey, 'existing-public');
      expect(config.localPrivateKey, 'existing-private');
    });

    test(
      'peer key can be set interactively and advanced fields are written',
      () async {
        final temp = await Directory.systemTemp.createTemp('btun_setup_test_');
        addTearDown(() => temp.delete(recursive: true));
        final output = StringBuffer();

        await _wizard(
          lines: [
            'client',
            'shared-session',
            'peer-key',
            '127.0.0.2',
            '1081',
            '3',
            'no',
          ],
          output: output,
          profile: temp.path,
        ).run();

        final config = await BtunConfig.load(
          BtunConfig.defaultConfigPath(temp.path),
        );
        expect(config.role, BtunRole.client);
        expect(config.sessionId, 'shared-session');
        expect(config.peerPublicKey, 'peer-key');
        expect(output.toString(), contains('client_public_key:'));
        expect(config.socksHost, '127.0.0.2');
        expect(config.socksPort, 1081);
        expect(config.transferMode, BtunTransferMode.lowLatency);
        expect(config.adaptive, BtunAdaptiveConfig.defaults);
        expect(config.maxRetryChunks, 64);
        expect(config.maxRetryBytes, 64 * 1024 * 1024);
      },
    );

    test('role argument overrides existing client config', () async {
      final temp = await Directory.systemTemp.createTemp('btun_setup_test_');
      addTearDown(() => temp.delete(recursive: true));
      final path = BtunConfig.defaultConfigPath(temp.path);
      await BtunConfig.defaults(
        profileDir: temp.path,
      ).copyWith(role: BtunRole.client).save(path);
      final output = StringBuffer();

      await _wizard(
        lines: [
          'yes',
          ..._defaultSetupLines(login: 'no', role: false),
        ],
        output: output,
        profile: temp.path,
        role: BtunRole.relay,
      ).run();

      final config = await BtunConfig.load(path);
      expect(config.role, BtunRole.relay);
      expect(output.toString(), contains('Using role relay.'));
    });

    test('transfer mode argument overrides setup prompt', () async {
      final temp = await Directory.systemTemp.createTemp('btun_setup_test_');
      addTearDown(() => temp.delete(recursive: true));
      final output = StringBuffer();

      await _wizard(
        lines: _defaultSetupLines(login: 'no', role: false, transfer: false),
        output: output,
        profile: temp.path,
        role: BtunRole.relay,
        transferMode: BtunTransferMode.bulk,
      ).run();

      final config = await BtunConfig.load(
        BtunConfig.defaultConfigPath(temp.path),
      );
      expect(config.transferMode, BtunTransferMode.bulk);
      expect(output.toString(), contains('Using transfer mode bulk.'));
    });
  });
}

BtunSetupWizard _wizard({
  required List<String> lines,
  required StringBuffer output,
  String? profile,
  BtunRole? role,
  BtunTransferMode? transferMode,
}) {
  var index = 0;
  return BtunSetupWizard(
    readLine: () => index < lines.length ? lines[index++] : null,
    write: output.write,
    writeln: output.writeln,
    profileFromArgs: profile,
    configPathFromArgs: null,
    sessionPathFromArgs: null,
    roleFromArgs: role,
    transferModeFromArgs: transferMode,
    loginRunner: (_) async => null,
  );
}

List<String> _defaultSetupLines({
  required String login,
  bool role = true,
  bool transfer = true,
}) => [...List.filled((role ? 3 : 2) + (transfer ? 1 : 0), ''), login];
