import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../data/datasources/local/folder_local_datasource.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../infrastructure/notifications/calendar_reminder_service.dart';
import '../../infrastructure/notifications/notification_service.dart';
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
  /// On iOS the BGTask handler and initial scheduling request are managed
  /// entirely from AppDelegate.swift to satisfy Apple's requirement that
  /// BGTaskScheduler.register is called before didFinishLaunchingWithOptions
  /// returns.  Calling registerPeriodicTask from Dart on iOS would invoke
  /// BGTaskScheduler.register a second time for the same identifier, which
  /// crashes the app.  On Android, WorkManager honours the interval closely.
  static Future<void> schedulePeriodicCheck({
    int intervalMinutes = 15,
  }) async {
    if (!_isMobile) return;
    if (Platform.isIOS) return;
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
///
/// The fetched inbox unread count is written into the same folder cache the
/// foreground app reads on launch, so the OS badge is correct the moment the
/// app is opened rather than waiting for the first live poll. This isolate
/// cannot reach the app's ad-hoc native badge channel directly — that channel
/// is only registered on the foreground engine (see MainActivity.kt /
/// SceneDelegate.swift) — so a local notification via flutter_local_notifications
/// (a real registered plugin, reachable here) is used instead to surface new
/// mail while the app is backgrounded.
///
/// Also reconciles calendar reminders for every account (see
/// [CalendarReminderService]) on this same cycle, so reminders keep getting
/// (re)scheduled even when the app is fully backgrounded/killed on mobile —
/// no second WorkManager/BGTaskScheduler task is registered for this.
Future<void> _runBackgroundPoll() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();

  final accountManager = sl<AccountManager>();
  await accountManager.initialize();

  final accounts = accountManager.accounts;
  if (accounts.isEmpty) return;

  final folderLocalDs = sl<FolderLocalDatasource>();
  final notifications = sl<NotificationService>();

  for (final account in accounts) {
    try {
      final ds = accountManager.buildEmailDatasourceForAccount(account);
      final freshFolders = await ds.getMailFolders();
      final freshInbox = freshFolders
          .where((f) => f.displayName.toLowerCase() == 'inbox')
          .firstOrNull;
      if (freshInbox == null) continue;

      final cached = await folderLocalDs.getCachedFolders(account.id);
      final cachedInbox =
          cached.where((f) => f.displayName.toLowerCase() == 'inbox').firstOrNull;

      // Preserve the rest of the cached tree (subfolders etc.) and only
      // refresh the Inbox entry — a background poll only fetches top-level
      // folders, so overwriting the whole cache would drop known subfolders.
      final toCache = cached.isNotEmpty
          ? cached
              .map((f) => f.displayName.toLowerCase() == 'inbox' ? freshInbox : f)
              .toList()
          : freshFolders;
      await folderLocalDs.clearFoldersForAccount(account.id);
      await folderLocalDs.cacheFolders(accountId: account.id, folders: toCache);

      // Use totalItemCount to detect new arrivals: unreadItemCount alone fails
      // when emails are read elsewhere AND new ones arrive simultaneously
      // (net unread can decrease even though new mail landed).
      if (cachedInbox != null &&
          freshInbox.totalItemCount > cachedInbox.totalItemCount) {
        final delta = freshInbox.totalItemCount - cachedInbox.totalItemCount;
        // Fetch the actual new emails so we can send one notification per email.
        // getEmails does NOT advance the shared delta token, so this is safe.
        try {
          final newEmails = await ds.getEmails(
            folderId: freshInbox.id,
            top: delta.clamp(1, 5),
            orderBy: 'receivedDateTime desc',
          );
          for (final email in newEmails.where((e) => !e.isRead).take(5)) {
            await notifications.showEmailNotification(
              emailId: email.id,
              accountId: account.id,
              subject: email.subject,
              senderName: email.from.displayName,
              accountLabel: account.displayName,
            );
          }
        } catch (_) {
          // Fall back silently — the foreground poller will notify on next wake.
        }
      }
    } catch (_) {
      // Silently skip accounts that fail; the foreground poller will retry.
    }
  }

  try {
    await sl<CalendarReminderService>().reconcileAll();
  } catch (_) {
    // Never let a calendar failure break the mail-poll return-true/false
    // contract above.
  }
}
