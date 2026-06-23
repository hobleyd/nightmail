import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../infrastructure/accounts/account_manager.dart';
import '../../injection_container.dart';

const _periodicTaskName = 'au.com.sharpblue.nightmail.mailCheck';
const _periodicTaskTag = 'mailCheck';

/// Platform-aware background mail polling service.
///
/// On mobile (iOS/Android) this wraps WorkManager so polling survives the app
/// being suspended or killed.  On desktop the [MailPollerCubit] timer runs
/// in-process and handles periodic checks while the app is running; the
/// methods here are no-ops on those platforms.
class BackgroundMailService {
  BackgroundMailService._();

  static bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Call once from [main] before [runApp] to wire up the WorkManager callback.
  /// Safe to call on all platforms — no-op on non-mobile.
  static Future<void> initialize() async {
    if (!_isMobile) return;
    await Workmanager().initialize(
      _callbackDispatcher,
      isInDebugMode: kDebugMode,
    );
  }

  /// Register a periodic background check. Safe to call multiple times —
  /// WorkManager deduplicates tasks by [_periodicTaskName].
  ///
  /// On iOS the system decides the exact run time; [intervalMinutes] is a
  /// minimum hint. On Android, WorkManager honours the interval closely.
  static Future<void> schedulePeriodicCheck({
    int intervalMinutes = 15,
  }) async {
    if (!_isMobile) return;
    await Workmanager().registerPeriodicTask(
      _periodicTaskName,
      _periodicTaskTag,
      frequency: Duration(minutes: intervalMinutes),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.linear,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  }

  /// Cancel any scheduled background checks.
  static Future<void> cancel() async {
    if (!_isMobile) return;
    await Workmanager().cancelByUniqueName(_periodicTaskName);
  }
}

/// Top-level entry point required by WorkManager — runs in a separate Dart
/// isolate.  Must be a free function annotated with vm:entry-point.
@pragma('vm:entry-point')
void _callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      await _runBackgroundPoll();
      return true;
    } catch (_) {
      return false;
    }
  });
}

/// Lightweight poll executed in the WorkManager background isolate.
///
/// Initialises a minimal DI context, loads accounts from secure storage, then
/// performs a folder-count poll for each account.  A simple folder poll (rather
/// than a Microsoft delta sync) is used deliberately: delta sync advances the
/// shared SQLite token, which causes the foreground [MailPollerCubit] to see
/// hasChanges=false on its next run and never trigger a UI refresh.  Folder
/// polling is enough to keep OAuth tokens from expiring.
Future<void> _runBackgroundPoll() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();

  final accountManager = sl<AccountManager>();
  await accountManager.initialize();

  final accounts = accountManager.accounts;
  if (accounts.isEmpty) return;

  for (final account in accounts) {
    try {
      final ds = accountManager.buildEmailDatasourceForAccount(account);
      await ds.getMailFolders();
    } catch (_) {
      // Silently skip accounts that fail; the foreground poller will retry.
    }
  }
}
