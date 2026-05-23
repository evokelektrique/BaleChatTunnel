import 'dart:async';
import 'dart:io';

import 'config.dart';

enum BtunConfigReloadMode { none, live, rebuild }

class BtunConfigDiff {
  const BtunConfigDiff(this.mode, this.reasons);

  final BtunConfigReloadMode mode;
  final List<String> reasons;

  bool get hasChanges => mode != BtunConfigReloadMode.none;
  bool get requiresRebuild => mode == BtunConfigReloadMode.rebuild;

  static BtunConfigDiff compare(BtunConfig oldConfig, BtunConfig nextConfig) {
    final live = <String>[];
    final rebuild = <String>[];

    if (!_sameAccounts(oldConfig.accounts, nextConfig.accounts)) {
      live.add('accounts');
    }
    if (oldConfig.pollInterval != nextConfig.pollInterval ||
        oldConfig.uploadMinInterval != nextConfig.uploadMinInterval ||
        oldConfig.uploadRateLimitPerMinute !=
            nextConfig.uploadRateLimitPerMinute ||
        oldConfig.maxInFlight != nextConfig.maxInFlight) {
      live.add('account transport tuning');
    }

    if (oldConfig.role != nextConfig.role) rebuild.add('role');
    if (oldConfig.database != nextConfig.database) rebuild.add('database');
    if (oldConfig.sessionId != nextConfig.sessionId) rebuild.add('session id');
    if (oldConfig.localPublicKey != nextConfig.localPublicKey ||
        oldConfig.localPrivateKey != nextConfig.localPrivateKey ||
        oldConfig.peerPublicKey != nextConfig.peerPublicKey) {
      rebuild.add('keys');
    }
    if (oldConfig.socksHost != nextConfig.socksHost ||
        oldConfig.socksPort != nextConfig.socksPort) {
      rebuild.add('SOCKS bind');
    }
    if (oldConfig.chunkSize != nextConfig.chunkSize ||
        oldConfig.bulkChunkSize != nextConfig.bulkChunkSize ||
        oldConfig.retryTimeout != nextConfig.retryTimeout ||
        oldConfig.ackFlushInterval != nextConfig.ackFlushInterval ||
        oldConfig.flushDelay != nextConfig.flushDelay ||
        oldConfig.bulkFlushDelay != nextConfig.bulkFlushDelay ||
        oldConfig.maxRetryChunks != nextConfig.maxRetryChunks ||
        oldConfig.maxRetryBytes != nextConfig.maxRetryBytes ||
        oldConfig.maxStreams != nextConfig.maxStreams) {
      rebuild.add('chunk transport tuning');
    }

    if (rebuild.isNotEmpty) {
      return BtunConfigDiff(BtunConfigReloadMode.rebuild, [
        ...rebuild,
        ...live,
      ]);
    }
    if (live.isNotEmpty) return BtunConfigDiff(BtunConfigReloadMode.live, live);
    return const BtunConfigDiff(BtunConfigReloadMode.none, []);
  }

  static bool _sameAccounts(
    List<BtunAccountConfig> oldAccounts,
    List<BtunAccountConfig> nextAccounts,
  ) {
    if (oldAccounts.length != nextAccounts.length) return false;
    final oldById = {
      for (final account in oldAccounts) account.userId: account,
    };
    for (final next in nextAccounts) {
      final old = oldById[next.userId];
      if (old == null) return false;
      if (old.sessionFile != next.sessionFile || old.enabled != next.enabled) {
        return false;
      }
    }
    return true;
  }
}

class BtunConfigWatcher {
  BtunConfigWatcher({
    required this.path,
    required this.onChanged,
    this.interval = const Duration(seconds: 2),
  });

  final String path;
  final Future<void> Function(BtunConfig config) onChanged;
  final Duration interval;
  Timer? _timer;
  DateTime? _lastModified;
  var _checking = false;

  Future<void> start() async {
    final file = File(path);
    if (await file.exists()) _lastModified = await file.lastModified();
    _timer = Timer.periodic(interval, (_) => unawaited(_check()));
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final modified = await file.lastModified();
      if (_lastModified != null && !modified.isAfter(_lastModified!)) return;
      _lastModified = modified;
      await onChanged(await BtunConfig.load(path));
    } finally {
      _checking = false;
    }
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
  }
}
