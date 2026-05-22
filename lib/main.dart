import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bale_chat_tunnel/btun.dart';
import 'package:bale_client/bale_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const appTitle = 'Bale Chat Tunnel';
const appPackageName = 'io.github.evokelektrique.bale_chat_tunnel';
const appVersionLabel = '0.1.0';

void main() {
  runApp(BtunApp(controller: BtunAppController()..load()));
}

class BtunApp extends StatelessWidget {
  const BtunApp({super.key, required this.controller});

  final BtunAppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return MaterialApp(
          title: appTitle,
          debugShowCheckedModeBanner: false,
          themeMode: controller.themeMode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: BtunHome(controller: controller),
        );
      },
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff0f766e),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        color: scheme.surfaceContainerLow,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

enum BtunPage { home, logs, settings }

enum RuntimeStatus { idle, loading, running, stopping, error }

enum LogLevel { info, warn, error }

String statusLabel(RuntimeStatus status) => switch (status) {
  RuntimeStatus.idle => 'Idle',
  RuntimeStatus.loading => 'Connecting',
  RuntimeStatus.running => 'Running',
  RuntimeStatus.stopping => 'Stopping',
  RuntimeStatus.error => 'Needs attention',
};

String readableError(Object error) {
  if (error is BaleAuthException) {
    return switch (error.authError) {
      BaleAuthError.invalid => 'Check the phone number and try again.',
      BaleAuthError.wrongCode => 'That login code is not correct.',
      BaleAuthError.wrongPassword => 'That password is not correct.',
      BaleAuthError.passwordNeeded => 'Enter your two-factor password.',
      BaleAuthError.signUpNeeded => 'Enter your name to create the account.',
      BaleAuthError.rateLimit => 'Too many attempts. Wait a bit and try again.',
      BaleAuthError.authLimit =>
        'Too many login attempts. Wait a bit and try again.',
      BaleAuthError.numberBanned => 'This phone number cannot be used.',
      BaleAuthError.unknown => 'Login failed. Check the details and try again.',
    };
  }
  final message = error.toString().replaceFirst(RegExp(r'^Exception: '), '');
  if (message.contains('SocketException')) {
    return 'Network connection failed. Check your internet connection.';
  }
  if (message.contains('TimeoutException') || message.contains('Timed out')) {
    return 'The request timed out. Try again.';
  }
  if (message.contains('FormatException')) {
    return 'One of the values has an invalid format.';
  }
  if (message.contains('Stop the client before changing the session name')) {
    return 'Disconnect before changing the session name.';
  }
  if (message.contains('Initialize settings first')) {
    return 'Create the client config in Settings first.';
  }
  if (message.contains('Log in before starting SOCKS')) {
    return 'Log in before connecting.';
  }
  return message.isEmpty ? 'Something went wrong. Try again.' : message;
}

class UiLogRecord {
  const UiLogRecord(this.level, this.message, this.time);

  final LogLevel level;
  final String message;
  final DateTime time;
}

class UiLogger extends Logger {
  UiLogger(this._sink);

  final void Function(LogLevel level, String message) _sink;

  @override
  void info(String message) => _sink(LogLevel.info, message);

  @override
  void warn(String message) => _sink(LogLevel.warn, message);

  @override
  void error(String message) => _sink(LogLevel.error, message);
}

class BtunAppController extends ChangeNotifier {
  BtunAppController({this.persistPrefs = true});

  final bool persistPrefs;

  var page = BtunPage.home;
  var status = RuntimeStatus.loading;
  var themeMode = ThemeMode.system;
  var profileDir = BtunConfig.defaultProfileDir();
  BtunConfig? config;
  BaleSession? session;
  String? error;
  final logs = <UiLogRecord>[];
  BtunClientRuntime? _runtime;

  bool get isRunning => status == RuntimeStatus.running;
  bool get isBusy =>
      status == RuntimeStatus.loading || status == RuntimeStatus.stopping;
  bool get isLoggedIn => session != null;
  bool get hasPeerKey => config?.peerPublicKey?.isNotEmpty ?? false;
  String get configPath => BtunConfig.defaultConfigPath(profileDir);
  String get sessionPath => BtunConfig.defaultSessionPath(profileDir);
  String get appPrefsPath => '$profileDir/gui.json';

  Future<void> load() async {
    status = RuntimeStatus.loading;
    notifyListeners();
    try {
      await _loadPrefs();
      config = await BtunConfig.tryLoad(configPath);
      await _restoreSession();
      status = RuntimeStatus.idle;
      _log(LogLevel.info, 'Ready.');
    } on Object catch (e) {
      error = readableError(e);
      status = RuntimeStatus.error;
      _log(LogLevel.error, error!);
    }
    notifyListeners();
  }

  void selectPage(BtunPage value) {
    page = value;
    notifyListeners();
  }

  void clearError() {
    error = null;
    if (status == RuntimeStatus.error) status = RuntimeStatus.idle;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    notifyListeners();
    await _savePrefs();
  }

  Future<void> setProfileDir(String value) async {
    if (value.trim().isEmpty) return;
    profileDir = value.trim();
    await load();
    await _savePrefs();
  }

  Future<void> initConfig() async {
    await _guard(() async {
      final existing = await BtunConfig.tryLoad(configPath);
      final localKeys = existing == null
          ? await BtunCrypto.generateKeyPair()
          : KeyPairConfig(
              publicKey: existing.localPublicKey,
              privateKey: existing.localPrivateKey,
            );
      final next = (existing ?? BtunConfig.defaults(profileDir: profileDir))
          .copyWith(
            role: BtunRole.client,
            sessionFile: sessionPath,
            database: BtunConfig.defaultDatabasePath(profileDir),
            localPublicKey: localKeys.publicKey,
            localPrivateKey: localKeys.privateKey,
          );
      await next.save(configPath);
      config = next;
      _log(LogLevel.info, 'Client config initialized at $configPath');
    });
  }

  Future<void> saveConfig({
    String? sessionId,
    String? peerPublicKey,
    String? socksHost,
    int? socksPort,
    int? maxInFlight,
    int? chunkSize,
    int? pollMs,
    int? uploadRateLimit,
  }) async {
    await _guard(() async {
      final current = config ?? BtunConfig.defaults(profileDir: profileDir);
      if (isRunning &&
          sessionId != null &&
          sessionId.trim() != current.sessionId) {
        throw Exception('Stop the client before changing the session name.');
      }
      final next = current.copyWith(
        role: BtunRole.client,
        sessionFile: sessionPath,
        database: BtunConfig.defaultDatabasePath(profileDir),
        sessionId: sessionId?.trim().isEmpty ?? true
            ? current.sessionId
            : sessionId!.trim(),
        peerPublicKey: peerPublicKey?.trim(),
        socksHost: socksHost?.trim().isEmpty ?? true
            ? current.socksHost
            : socksHost!.trim(),
        socksPort: socksPort,
        maxInFlight: maxInFlight,
        chunkSize: chunkSize,
        pollInterval: pollMs == null ? null : Duration(milliseconds: pollMs),
        uploadRateLimitPerMinute: uploadRateLimit,
      );
      await next.save(configPath);
      config = next;
      _log(LogLevel.info, 'Settings saved.');
    });
  }

  Future<void> startClient() async {
    await _guard(() async {
      final current = config;
      if (current == null) throw Exception('Initialize settings first.');
      if (session == null) throw Exception('Log in before starting SOCKS.');
      status = RuntimeStatus.loading;
      notifyListeners();
      final runtime =
          await createBtunClientRuntime(
            config: current.copyWith(role: BtunRole.client),
            logger: UiLogger(_log),
          ).timeout(
            const Duration(seconds: 25),
            onTimeout: () {
              throw Exception(
                'Timed out while connecting to Bale. Check network access to Bale and try again.',
              );
            },
          );
      try {
        await runtime.start().timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            throw Exception(
              'Timed out while starting the tunnel. Check Bale connectivity and the SOCKS host/port.',
            );
          },
        );
      } on Object {
        await runtime.close();
        rethrow;
      }
      _runtime = runtime;
      status = RuntimeStatus.running;
      _log(
        LogLevel.info,
        'SOCKS5 listening on ${runtime.host}:${runtime.port}',
      );
    });
  }

  Future<void> stopClient() async {
    if (_runtime == null) return;
    status = RuntimeStatus.stopping;
    notifyListeners();
    try {
      await _runtime?.close();
      _runtime = null;
      status = RuntimeStatus.idle;
      _log(LogLevel.info, 'Client stopped.');
    } on Object catch (e) {
      error = readableError(e);
      status = RuntimeStatus.error;
      _log(LogLevel.error, error!);
    }
    notifyListeners();
  }

  Future<PhoneAuthResponse> startLogin(String phone) async {
    final client = BaleClient(
      credentialsStore: FileBaleCredentialsStore(sessionPath),
    );
    try {
      final response = await client.startPhoneAuth(phone.trim());
      _log(LogLevel.info, 'Login code sent.');
      return response;
    } finally {
      await client.close();
    }
  }

  Future<LoginResult> validateLoginCode({
    required String transactionHash,
    required String code,
  }) async {
    final client = BaleClient(
      credentialsStore: FileBaleCredentialsStore(sessionPath),
    );
    try {
      final signedIn = await client.validateCode(
        transactionHash: transactionHash,
        code: code.trim(),
      );
      session = signedIn;
      _log(LogLevel.info, 'Logged in as user ${signedIn.userId ?? 'unknown'}.');
      notifyListeners();
      return LoginResult.complete;
    } on BaleAuthException catch (e) {
      if (e.authError == BaleAuthError.passwordNeeded) {
        return LoginResult.passwordNeeded;
      }
      if (e.authError == BaleAuthError.signUpNeeded) {
        return LoginResult.signUpNeeded;
      }
      rethrow;
    } finally {
      await client.close();
    }
  }

  Future<void> validatePassword({
    required String transactionHash,
    required String password,
  }) async {
    final client = BaleClient(
      credentialsStore: FileBaleCredentialsStore(sessionPath),
    );
    try {
      session = await client.validatePassword(
        transactionHash: transactionHash,
        password: password,
      );
      _log(LogLevel.info, 'Two-factor login complete.');
      notifyListeners();
    } finally {
      await client.close();
    }
  }

  Future<void> signUp({
    required String transactionHash,
    required String name,
  }) async {
    final client = BaleClient(
      credentialsStore: FileBaleCredentialsStore(sessionPath),
    );
    try {
      session = await client.signUp(
        transactionHash: transactionHash,
        name: name.trim(),
      );
      _log(LogLevel.info, 'Account created and logged in.');
      notifyListeners();
    } finally {
      await client.close();
    }
  }

  Future<void> logout() async {
    await stopClient();
    final client = BaleClient(
      credentialsStore: FileBaleCredentialsStore(sessionPath),
    );
    try {
      await client.logout();
      session = null;
      _log(LogLevel.info, 'Logged out.');
    } finally {
      await client.close();
    }
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  Future<void> _restoreSession() async {
    final client = BaleClient(
      credentialsStore: FileBaleCredentialsStore(sessionPath),
    );
    try {
      session = await client.restoreSession();
    } finally {
      await client.close();
    }
  }

  Future<void> _loadPrefs() async {
    if (!persistPrefs) return;
    final file = File(appPrefsPath);
    if (!await file.exists()) return;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) return;
    themeMode = switch (decoded['theme_mode']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> _savePrefs() async {
    if (!persistPrefs) return;
    final file = File(appPrefsPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'theme_mode': themeMode.name}),
    );
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      error = null;
      await action();
      if (status == RuntimeStatus.error) status = RuntimeStatus.idle;
    } on Object catch (e) {
      error = readableError(e);
      status = RuntimeStatus.error;
      _log(LogLevel.error, error!);
    }
    notifyListeners();
  }

  void _log(LogLevel level, String message) {
    logs.insert(0, UiLogRecord(level, message, DateTime.now()));
    if (logs.length > 500) logs.removeLast();
    notifyListeners();
  }
}

enum LoginResult { complete, passwordNeeded, signUpNeeded }

class BtunHome extends StatelessWidget {
  const BtunHome({super.key, required this.controller});

  final BtunAppController controller;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    final content = AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return switch (controller.page) {
          BtunPage.home => HomeTab(controller: controller),
          BtunPage.logs => LogsTab(controller: controller),
          BtunPage.settings => SettingsTab(controller: controller),
        };
      },
    );
    return Scaffold(
      body: compact
          ? Column(
              children: [
                Expanded(child: content),
                NavigationBar(
                  selectedIndex: controller.page.index,
                  onDestinationSelected: (i) =>
                      controller.selectPage(BtunPage.values[i]),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: 'Home',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.article_outlined),
                      selectedIcon: Icon(Icons.article),
                      label: 'Logs',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.tune_outlined),
                      selectedIcon: Icon(Icons.tune),
                      label: 'Settings',
                    ),
                  ],
                ),
              ],
            )
          : Row(
              children: [
                NavigationRail(
                  backgroundColor: Theme.of(context).colorScheme.surface,
                  selectedIndex: controller.page.index,
                  onDestinationSelected: (i) =>
                      controller.selectPage(BtunPage.values[i]),
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: Text('Home'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.article_outlined),
                      selectedIcon: Icon(Icons.article),
                      label: Text('Logs'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.tune_outlined),
                      selectedIcon: Icon(Icons.tune),
                      label: Text('Settings'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            ),
    );
  }
}

class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.controller});

  final BtunAppController controller;

  @override
  Widget build(BuildContext context) {
    return CleanPage(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (controller.error != null)
                  ErrorBanner(
                    message: controller.error!,
                    onClose: controller.clearError,
                  ),
                ConnectionControl(controller: controller),
                const SizedBox(height: 24),
                SetupStatusList(controller: controller, centered: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ConnectionControl extends StatelessWidget {
  const ConnectionControl({super.key, required this.controller});

  final BtunAppController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = controller.isRunning;
    final busy = controller.isBusy;
    final ready =
        controller.config != null &&
        controller.isLoggedIn &&
        controller.hasPeerKey;
    final loginPrompt = !busy && !running && !controller.isLoggedIn;
    final enabled = !busy && (running || ready);
    final color = running
        ? Colors.green
        : !enabled
        ? scheme.outline
        : scheme.primary;
    final label = switch (controller.status) {
      RuntimeStatus.running => 'Connected',
      RuntimeStatus.loading => 'Connecting',
      RuntimeStatus.stopping => 'Stopping',
      RuntimeStatus.error => 'Connection blocked',
      RuntimeStatus.idle => 'Disconnected',
    };
    return Column(
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.96, end: running ? 1.02 : 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: running
                  ? controller.stopClient
                  : ready
                  ? controller.startClient
                  : loginPrompt
                  ? () => showLoginDialog(context, controller)
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                width: 190,
                height: 190,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      color.withValues(alpha: running ? 0.24 : 0.13),
                      color.withValues(alpha: running ? 0.10 : 0.05),
                    ],
                  ),
                  border: Border.all(
                    color: color.withValues(alpha: running ? 0.80 : 0.48),
                    width: running ? 3 : 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(
                        alpha: enabled
                            ? running
                                  ? 0.26
                                  : 0.10
                            : 0.04,
                      ),
                      blurRadius: running ? 52 : 32,
                      spreadRadius: running ? 5 : 1,
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (busy)
                      SizedBox(
                        width: 166,
                        height: 166,
                        child: CircularProgressIndicator(
                          color: color,
                          strokeWidth: 3,
                        ),
                      ),
                    Icon(Icons.power_settings_new, color: color, size: 68),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          controller.config == null
              ? 'Finish setup in Settings'
              : !controller.isLoggedIn
              ? 'Login to continue'
              : !controller.hasPeerKey
              ? 'Add relay key in Settings'
              : 'Session ${controller.config!.sessionId}',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class SetupStatusList extends StatelessWidget {
  const SetupStatusList({
    super.key,
    required this.controller,
    this.centered = false,
  });

  final BtunAppController controller;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final steps = [
      _SetupStep(
        controller.config != null,
        'Config',
        controller.config == null ? 'Create config' : 'Ready',
      ),
      _SetupStep(
        controller.isLoggedIn,
        'Bale',
        controller.isLoggedIn ? 'Logged in' : 'Login required',
      ),
      _SetupStep(
        controller.hasPeerKey,
        'Relay key',
        controller.hasPeerKey ? 'Configured' : 'Paste relay key',
      ),
    ];
    final list = SizedBox(
      width: centered ? 250 : double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final step in steps) _CheckRow(step: step, compact: centered),
        ],
      ),
    );
    return centered ? Center(child: list) : list;
  }
}

class _SetupStep {
  const _SetupStep(this.done, this.title, this.help);

  final bool done;
  final String title;
  final String help;
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.done});

  final bool done;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? Colors.green : Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.step, this.compact = false});

  final _SetupStep step;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          _StatusDot(done: step.done),
          const SizedBox(width: 12),
          SizedBox(
            width: compact ? 84 : 86,
            child: Text(
              step.title,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: compact ? 112 : null,
            child: Text(
              step.help,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ExchangePanel extends StatelessWidget {
  const ExchangePanel({super.key, required this.controller, this.config});

  final BtunAppController controller;
  final BtunConfig? config;

  @override
  Widget build(BuildContext context) {
    final setupText = config == null
        ? null
        : 'btun client setup\nsession_id: ${config!.sessionId}\nclient_public_key: ${config!.localPublicKey}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              icon: Icons.hub_outlined,
              title: 'Key Exchange',
              dense: true,
              trailing: setupText == null
                  ? null
                  : IconButton(
                      tooltip: 'Copy setup info for relay',
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: setupText)),
                      icon: const Icon(Icons.copy),
                    ),
            ),
            const SizedBox(height: 10),
            SetupStatusList(controller: controller),
            const SizedBox(height: 8),
            InfoLine(label: 'Profile', value: controller.profileDir),
            InfoLine(
              label: 'Session ID',
              value: config?.sessionId ?? 'Initialize config first',
              copyValue: config?.sessionId,
            ),
            InfoLine(
              label: 'Client public key',
              value: config?.localPublicKey ?? 'Initialize config first',
              copyValue: config?.localPublicKey,
            ),
            InfoLine(
              label: 'Need from relay',
              value: controller.hasPeerKey ? 'Configured' : 'Relay public key',
            ),
          ],
        ),
      ),
    );
  }
}

class StatusPanel extends StatelessWidget {
  const StatusPanel({super.key, required this.controller});

  final BtunAppController controller;

  @override
  Widget build(BuildContext context) {
    final config = controller.config;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusBadge(
          icon: Icons.power_settings_new,
          label: 'Client',
          value: statusLabel(controller.status),
          good: controller.isRunning,
        ),
        StatusBadge(
          icon: Icons.verified_user_outlined,
          label: 'Bale',
          value: controller.isLoggedIn ? 'Logged in' : 'Not logged in',
          good: controller.isLoggedIn,
        ),
        StatusBadge(
          icon: Icons.lan_outlined,
          label: 'SOCKS5',
          value: config == null
              ? 'Not configured'
              : '${config.socksHost}:${config.socksPort}',
          good: config != null,
        ),
      ],
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.good,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool good;

  @override
  Widget build(BuildContext context) {
    final color = good ? Colors.green : Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          _StatusDot(done: good),
          const SizedBox(width: 12),
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 12),
          SizedBox(
            width: 70,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key, required this.controller});

  final BtunAppController controller;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  late final TextEditingController profile;
  late final TextEditingController sessionId;
  late final TextEditingController peerKey;
  late final TextEditingController host;
  late final TextEditingController port;
  late final TextEditingController maxInFlight;
  late final TextEditingController chunkSize;
  late final TextEditingController pollMs;
  late final TextEditingController uploadRate;
  Timer? saveDebounce;

  @override
  void initState() {
    super.initState();
    profile = TextEditingController(text: widget.controller.profileDir);
    sessionId = TextEditingController();
    peerKey = TextEditingController();
    host = TextEditingController();
    port = TextEditingController();
    maxInFlight = TextEditingController();
    chunkSize = TextEditingController();
    pollMs = TextEditingController();
    uploadRate = TextEditingController();
    _sync();
  }

  @override
  void didUpdateWidget(covariant SettingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final config = widget.controller.config;
    if (config == null) return;
    sessionId.text = config.sessionId;
    peerKey.text = config.peerPublicKey ?? '';
    host.text = config.socksHost;
    port.text = config.socksPort.toString();
    maxInFlight.text = config.maxInFlight.toString();
    chunkSize.text = config.chunkSize.toString();
    pollMs.text = config.pollInterval.inMilliseconds.toString();
    uploadRate.text = config.uploadRateLimitPerMinute.toString();
  }

  @override
  void dispose() {
    saveDebounce?.cancel();
    profile.dispose();
    sessionId.dispose();
    peerKey.dispose();
    host.dispose();
    port.dispose();
    maxInFlight.dispose();
    chunkSize.dispose();
    pollMs.dispose();
    uploadRate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.controller.config;
    return AppPage(
      title: 'Settings',
      subtitle: 'Client profile, peer key, SOCKS, performance, and appearance',
      child: Builder(
        builder: (context) {
          final profileCard = Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader(
                    icon: Icons.folder_outlined,
                    title: 'Profile',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: sessionId,
                          enabled: !widget.controller.isRunning,
                          onChanged: (_) => _scheduleSave(),
                          decoration: const InputDecoration(
                            labelText: 'Session name',
                            helperText: 'Stop the client before changing it.',
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (config == null) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _initConfig,
                        icon: const Icon(Icons.key),
                        label: const Text('Initialize config'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: profile,
                          decoration: const InputDecoration(
                            labelText: 'Profile directory',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: () =>
                            widget.controller.setProfileDir(profile.text),
                        child: const Text('Load'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
          final exchangeCard = ExchangePanel(
            controller: widget.controller,
            config: config,
          );
          final tunnelCard = Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(
                    icon: Icons.vpn_key_outlined,
                    title: 'Tunnel',
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        IconButton(
                          tooltip: 'Paste relay public key',
                          onPressed: () async {
                            final data = await Clipboard.getData('text/plain');
                            if (data?.text?.trim().isNotEmpty ?? false) {
                              peerKey.text = data!.text!.trim();
                              _scheduleSave();
                            }
                          },
                          icon: const Icon(Icons.content_paste),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: peerKey,
                    enabled: !widget.controller.isRunning,
                    maxLines: 1,
                    onChanged: (_) => _scheduleSave(),
                    decoration: const InputDecoration(
                      labelText: 'Relay public key',
                      helperText:
                          'Paste the relay machine local public key here.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: host,
                          enabled: !widget.controller.isRunning,
                          onChanged: (_) => _scheduleSave(),
                          decoration: const InputDecoration(
                            labelText: 'SOCKS host',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 150,
                        child: TextField(
                          controller: port,
                          enabled: !widget.controller.isRunning,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => _scheduleSave(),
                          decoration: const InputDecoration(
                            labelText: 'SOCKS port',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const SectionHeader(
                    icon: Icons.speed_outlined,
                    title: 'Performance',
                    dense: true,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      NumberField(
                        label: 'Chunk bytes',
                        controller: chunkSize,
                        onChanged: _scheduleSave,
                      ),
                      NumberField(
                        label: 'Max uploads',
                        controller: maxInFlight,
                        onChanged: _scheduleSave,
                      ),
                      NumberField(
                        label: 'Poll ms',
                        controller: pollMs,
                        onChanged: _scheduleSave,
                      ),
                      NumberField(
                        label: 'Uploads / min',
                        controller: uploadRate,
                        onChanged: _scheduleSave,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
          final appearanceCard = Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader(
                    icon: Icons.palette_outlined,
                    title: 'Appearance',
                    dense: true,
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto),
                        label: Text('System'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode),
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode),
                        label: Text('Dark'),
                      ),
                    ],
                    selected: {widget.controller.themeMode},
                    onSelectionChanged: (values) =>
                        widget.controller.setThemeMode(values.first),
                  ),
                ],
              ),
            ),
          );
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              profileCard,
              const SizedBox(height: 16),
              tunnelCard,
              const SizedBox(height: 16),
              exchangeCard,
              const SizedBox(height: 16),
              appearanceCard,
              const SizedBox(height: 20),
              Center(
                child: Text(
                  '$appTitle $appVersionLabel',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _save() async {
    await widget.controller.saveConfig(
      sessionId: sessionId.text,
      peerPublicKey: peerKey.text,
      socksHost: host.text,
      socksPort: int.tryParse(port.text),
      maxInFlight: int.tryParse(maxInFlight.text),
      chunkSize: int.tryParse(chunkSize.text),
      pollMs: int.tryParse(pollMs.text),
      uploadRateLimit: int.tryParse(uploadRate.text),
    );
  }

  Future<void> _initConfig() async {
    await widget.controller.initConfig();
    _sync();
  }

  void _scheduleSave() {
    if (widget.controller.isRunning) return;
    saveDebounce?.cancel();
    saveDebounce = Timer(const Duration(milliseconds: 450), _save);
  }
}

class LogsTab extends StatefulWidget {
  const LogsTab({super.key, required this.controller});

  final BtunAppController controller;

  @override
  State<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<LogsTab> {
  final query = TextEditingController();

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final term = query.text.toLowerCase();
    final records = widget.controller.logs
        .where((log) => log.message.toLowerCase().contains(term))
        .toList();
    return AppPage(
      title: 'Logs',
      subtitle: 'Runtime events from the client tunnel',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: query,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Search logs',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Clear logs',
                  onPressed: widget.controller.clearLogs,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              itemCount: records.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) => LogTile(record: records[index]),
            ),
          ),
        ],
      ),
    );
  }
}

class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.actions = const [],
  });

  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return CleanPage(child: child);
  }
}

class CleanPage extends StatelessWidget {
  const CleanPage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(child: child),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
    this.dense = false,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Container(
          width: dense ? 28 : 34,
          height: dense ? 28 : 34,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: dense ? 17 : 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: dense
                ? Theme.of(context).textTheme.titleMedium
                : Theme.of(context).textTheme.titleLarge,
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChecklistRow extends StatelessWidget {
  const ChecklistRow({
    super.key,
    required this.done,
    required this.title,
    required this.subtitle,
    required this.action,
  });

  final bool done;
  final String title;
  final String subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? Colors.green : Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 92),
            child: action,
          ),
        ],
      ),
    );
  }
}

class InfoLine extends StatelessWidget {
  const InfoLine({
    super.key,
    required this.label,
    required this.value,
    this.copyValue,
  });

  final String label;
  final String value;
  final String? copyValue;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 120,
                child: Text(
                  label,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: SelectableText(
                  value,
                  maxLines: 2,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
              if (copyValue != null)
                IconButton(
                  tooltip: 'Copy $label',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: copyValue!)),
                  icon: const Icon(Icons.copy, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class NumberField extends StatelessWidget {
  const NumberField({
    super.key,
    required this.label,
    required this.controller,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 148,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        onChanged: (_) => onChanged?.call(),
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}

class LogTile extends StatelessWidget {
  const LogTile({super.key, required this.record});

  final UiLogRecord record;

  @override
  Widget build(BuildContext context) {
    final color = switch (record.level) {
      LogLevel.info => Theme.of(context).colorScheme.primary,
      LogLevel.warn => Colors.orange,
      LogLevel.error => Theme.of(context).colorScheme.error,
    };
    final time =
        '${record.time.hour.toString().padLeft(2, '0')}:'
        '${record.time.minute.toString().padLeft(2, '0')}:'
        '${record.time.second.toString().padLeft(2, '0')}';
    return Card(
      child: ListTile(
        leading: Icon(Icons.circle, color: color, size: 12),
        title: Text(record.message),
        subtitle: Text(time),
        dense: true,
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: MaterialBanner(
        leading: const Icon(Icons.error_outline),
        content: Text(message),
        actions: [TextButton(onPressed: onClose, child: const Text('Dismiss'))],
      ),
    );
  }
}

Future<void> showLoginDialog(
  BuildContext context,
  BtunAppController controller,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => LoginDialog(controller: controller),
  );
}

class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key, required this.controller});

  final BtunAppController controller;

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  final phone = TextEditingController();
  final code = TextEditingController();
  final password = TextEditingController();
  final name = TextEditingController();
  String? transactionHash;
  var step = _LoginStep.phone;
  var busy = false;
  String? error;

  @override
  void dispose() {
    phone.dispose();
    code.dispose();
    password.dispose();
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Login'),
      content: SizedBox(
        width: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.errorContainer.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ),
            if (step == _LoginStep.phone)
              TextField(
                controller: phone,
                decoration: const InputDecoration(
                  labelText: 'Phone number',
                  hintText: '+98912...',
                  prefixIcon: Icon(Icons.phone),
                ),
              ),
            if (step == _LoginStep.code)
              TextField(
                controller: code,
                decoration: const InputDecoration(
                  labelText: 'Login code',
                  prefixIcon: Icon(Icons.password),
                ),
              ),
            if (step == _LoginStep.password)
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Two-factor password',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
            if (step == _LoginStep.signUp)
              TextField(
                controller: name,
                decoration: const InputDecoration(
                  labelText: 'Account name',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : _next,
          child: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(step == _LoginStep.phone ? 'Send Code' : 'Continue'),
        ),
      ],
    );
  }

  Future<void> _next() async {
    final validationError = switch (step) {
      _LoginStep.phone when phone.text.trim().isEmpty =>
        'Enter your phone number.',
      _LoginStep.code when code.text.trim().isEmpty => 'Enter the login code.',
      _LoginStep.password when password.text.isEmpty => 'Enter your password.',
      _LoginStep.signUp when name.text.trim().isEmpty => 'Enter your name.',
      _ => null,
    };
    if (validationError != null) {
      setState(() => error = validationError);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      switch (step) {
        case _LoginStep.phone:
          final response = await widget.controller.startLogin(phone.text);
          transactionHash = response.transactionHash;
          step = _LoginStep.code;
        case _LoginStep.code:
          final result = await widget.controller.validateLoginCode(
            transactionHash: transactionHash!,
            code: code.text,
          );
          if (result == LoginResult.complete && mounted) {
            Navigator.of(context).pop();
          } else if (result == LoginResult.passwordNeeded) {
            step = _LoginStep.password;
          } else {
            step = _LoginStep.signUp;
          }
        case _LoginStep.password:
          await widget.controller.validatePassword(
            transactionHash: transactionHash!,
            password: password.text,
          );
          if (mounted) Navigator.of(context).pop();
        case _LoginStep.signUp:
          await widget.controller.signUp(
            transactionHash: transactionHash!,
            name: name.text,
          );
          if (mounted) Navigator.of(context).pop();
      }
    } on Object catch (e) {
      error = readableError(e);
    }
    if (mounted) {
      setState(() {
        busy = false;
      });
    }
  }
}

enum _LoginStep { phone, code, password, signUp }
