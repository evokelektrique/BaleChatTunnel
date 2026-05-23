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

    test('parses transport presets and legacy aliases', () {
      expect(
        parseTransportPreset('', defaultValue: BtunTransportPreset.stable),
        BtunTransportPreset.stable,
      );
      expect(
        parseTransportPreset(
          'interactive',
          defaultValue: BtunTransportPreset.stable,
        ),
        BtunTransportPreset.interactive,
      );
      expect(
        parseTransportPreset(
          'balanced',
          defaultValue: BtunTransportPreset.custom,
        ),
        BtunTransportPreset.stable,
      );
      expect(
        parseTransportPreset('slow', defaultValue: BtunTransportPreset.custom),
        BtunTransportPreset.resilient,
      );
      expect(
        () => parseTransportPreset(
          'reckless',
          defaultValue: BtunTransportPreset.stable,
        ),
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
      expect(config.allowPorts, [80, 443]);
      expect(config.blockPrivateIps, isTrue);
      expect(config.dnsOnRelay, isTrue);
      expect(config.localPublicKey, isNotEmpty);
      expect(config.peerPublicKey, '');
      expect(output.toString(), contains('relay_public_key:'));
      expect(output.toString(), contains('Missing Client public key.'));
      expect(output.toString(), contains('btun login --profile ${temp.path}'));
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
        lines: [
          'yes',
          ..._defaultSetupLines(login: 'no'),
        ],
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
            'custom',
            '111111',
            '222222',
            '3',
            '1500',
            '30000',
            '25',
            '30',
            '400',
            '50',
            '60',
            '7',
            '123456',
            '9',
            'yes',
            '80,443,8443',
            'false',
            'false',
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
        expect(config.allowPorts, [80, 443, 8443]);
        expect(config.blockPrivateIps, isFalse);
        expect(config.dnsOnRelay, isFalse);
        expect(config.socksHost, '127.0.0.2');
        expect(config.socksPort, 1081);
        expect(config.chunkSize, 111111);
        expect(config.bulkChunkSize, 222222);
        expect(config.maxInFlight, 3);
        expect(config.pollInterval.inMilliseconds, 1500);
        expect(config.retryTimeout.inMilliseconds, 30000);
        expect(config.uploadMinInterval.inMilliseconds, 25);
        expect(config.uploadRateLimitPerMinute, 30);
        expect(config.ackFlushInterval.inMilliseconds, 400);
        expect(config.flushDelay.inMilliseconds, 50);
        expect(config.bulkFlushDelay.inMilliseconds, 60);
        expect(config.maxRetryChunks, 7);
        expect(config.maxRetryBytes, 123456);
        expect(config.maxStreams, 9);
        expect(config.transportPreset, BtunTransportPreset.custom);
      },
    );

    test('relay policy can be skipped during setup', () async {
      final temp = await Directory.systemTemp.createTemp('btun_setup_test_');
      addTearDown(() => temp.delete(recursive: true));

      await _wizard(
        lines: _defaultSetupLines(login: 'no'),
        output: StringBuffer(),
        profile: temp.path,
      ).run();

      final config = await BtunConfig.load(
        BtunConfig.defaultConfigPath(temp.path),
      );
      expect(config.allowPorts, [80, 443]);
      expect(config.blockPrivateIps, isTrue);
      expect(config.dnsOnRelay, isTrue);
    });
  });
}

BtunSetupWizard _wizard({
  required List<String> lines,
  required StringBuffer output,
  String? profile,
}) {
  var index = 0;
  return BtunSetupWizard(
    readLine: () => index < lines.length ? lines[index++] : null,
    write: output.write,
    writeln: output.writeln,
    profileFromArgs: profile,
    configPathFromArgs: null,
    sessionPathFromArgs: null,
    loginRunner: (_, _) async => true,
  );
}

List<String> _defaultSetupLines({required String login}) => [
  ...List.filled(7, ''),
  login,
];
