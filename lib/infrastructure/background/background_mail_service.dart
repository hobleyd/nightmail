import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/error/exceptions.dart';
import '../../data/datasources/local/delta_token_datasource.dart';
import '../../data/datasources/remote/graph_delta_datasource.dart';
import '../../infrastructure/accounts/account.dart';
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
      existingWorkPolicy: ExistingWorkPolicy.replace,
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
/// runs a single poll cycle for each account — keeping delta tokens fresh and
/// the SQLite cache up-to-date so the inbox is populated immediately when the
/// user opens the app.
Future<void> _runBackgroundPoll() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();

  final accountManager = sl<AccountManager>();
  await accountManager.initialize();

  final accounts = accountManager.accounts;
  if (accounts.isEmpty) return;

  final database = sl<DeltaTokenDatasource>();

  for (final account in accounts) {
    try {
      final ds = accountManager.buildEmailDatasourceForAccount(account);

      if (account is MicrosoftAccount && ds is GraphDeltaDatasource) {
        final savedToken =
            await database.loadDeltaToken(account.id, 'inbox');
        if (savedToken != null) {
          // Incremental delta sync keeps the token fresh and the local cache
          // up-to-date so the foreground app can show changes immediately.
          final result =
              await ds.syncMailDelta('inbox', deltaLink: savedToken);
          await database.saveDeltaToken(
              account.id, 'inbox', result.deltaLink);
        } else {
          // No token yet — a lightweight folder poll is enough to warm up
          // the connection until the main app bootstraps the delta token.
          await ds.getMailFolders();
        }
      } else {
        // Gmail / IMAP: folder-count poll keeps OAuth tokens from expiring
        // and gives us a freshness signal when the app comes to foreground.
        await ds.getMailFolders();
      }
    } on ServerException catch (e) {
      if (e.statusCode == 410) {
        // Expired delta token — clear it so the next foreground poll
        // bootstraps a fresh one.
        await database.clearDeltaTokensForAccount(account.id);
      }
    } catch (_) {
      // Silently skip accounts that fail; the foreground poller will retry.
    }
  }
}
