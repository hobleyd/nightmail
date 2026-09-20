import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../core/platform/window_utils.dart';
import '../../domain/usecases/delete_email.dart';
import '../../domain/usecases/mark_email_as_read.dart';
import '../../injection_container.dart';
import 'notification_action.dart';
import 'reminder_reconcile_channel.dart';

// Top-level callback — required for background isolate on Android when the
// app is killed and the user taps a notification, and reached on iOS too:
// flutter_local_notifications' iOS side spins up its own headless Flutter
// engine for a background action tap (FlutterEngineManager), the same shape
// WorkManager's _callbackDispatcher (background_mail_service.dart) already
// uses. "async" with a declared void return is deliberate: the callback
// typedef is `void Function(NotificationResponse)`, and this is the
// standard fire-and-forget shape for it — there is no caller awaiting this.
@pragma('vm:entry-point')
void _onBackgroundNotificationResponse(NotificationResponse details) async {
  final actionId = details.actionId;
  if (actionId != NotificationService.markReadActionId &&
      actionId != NotificationService.deleteActionId) {
    // A plain tap (open) or Dismiss: nothing to do off-UI. A cold-launch
    // open is picked up via getNotificationAppLaunchDetails when the app
    // starts; Dismiss needs no handling — the OS already removes it.
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();
  final service = sl<NotificationService>();
  final action = service._parsePayload(details.payload);
  if (action is OpenEmailAction) {
    await service.handleMailAction(
      actionId: actionId!,
      emailId: action.emailId,
      accountId: action.accountId,
    );
  }
}

class NotificationService {
  static const _macChannel =
      MethodChannel('au.com.sharpblue.nightmail/notifications');

  /// The category a mail notification is shown under, and its three action
  /// identifiers, in the order they're declared (Dismiss, Mark Read,
  /// Delete) — Apple shows action buttons in declaration order on both iOS
  /// and, since watchOS mirrors a category's actions from the iPhone app
  /// with no watchOS app/extension of NightMail's own required, on an
  /// Apple Watch too. macOS registers the same identifiers natively (see
  /// MainFlutterWindow.swift) so [handleMailAction] is the one place that
  /// owns what each action actually does, regardless of which native side
  /// dispatched it.
  static const mailCategoryIdentifier = 'MAIL_CATEGORY';
  static const dismissActionId = 'MAIL_DISMISS';
  static const markReadActionId = 'MAIL_MARK_READ';
  static const deleteActionId = 'MAIL_DELETE';

  static final _localPlugin = FlutterLocalNotificationsPlugin();
  static Future<void>? _localInitFuture;

  /// The `flutter_local_notifications` plugin, or null in a sub-window engine —
  /// every call through it is a deliberate no-op there.
  ///
  /// The plugin belongs to the main window alone. On Windows it is FFI-based:
  /// `initialize` hands the native DLL a `NativeCallable.listener` trampoline
  /// owned by the calling isolate and nothing ever disposes it. Because
  /// `desktop_multi_window` gives every sub-window its own engine and isolate,
  /// a sub-window that so much as constructed this service registered a second
  /// native plugin against the same app user model id — and closing that window
  /// killed its isolate, deleting the trampoline while the native side kept the
  /// pointer. The next toast activation then invoked a deleted callback, which
  /// is a *fatal VM abort* ("Callback invoked after it has been deleted"), not a
  /// catchable exception: it took the entire process down, main window included.
  ///
  /// Nothing is lost by staying quiet in sub-windows. CalendarReminderService
  /// and TaskReminderService run in the main window, reconcile every account's
  /// events against the persisted schedule tables, and are already the
  /// authority for what the OS actually holds.
  static FlutterLocalNotificationsPlugin? get _plugin =>
      AppWindow.isMain ? _localPlugin : null;

  final _linuxTimers = <String, Timer>{};
  final _actionController = StreamController<NotificationAction>.broadcast();
  NotificationAction? _pendingAction;

  Stream<NotificationAction> get actions => _actionController.stream;

  NotificationService() {
    if (Platform.isMacOS) {
      _macChannel.setMethodCallHandler(_handleNativeCall);
    } else {
      _initLocalNotifications();
    }
  }

  // Memoized as a Future (not a bool flag) so concurrent callers await the
  // same in-flight initialization instead of racing ahead of it — on Windows
  // the native plugin does COM/registry setup that can outlast the
  // constructor's fire-and-forget call, so a bool flag let scheduleEventReminder
  // call zonedSchedule before the plugin had actually finished initializing.
  Future<void> _initLocalNotifications() {
    // Sub-windows must never register the native callback — see [_plugin].
    if (!AppWindow.isMain) return Future.value();
    return _localInitFuture ??= _doInitLocalNotifications();
  }

  /// Awaits plugin initialization and checks whether the app was launched by
  /// a notification tap (iOS/Android terminated-state). Call once in main()
  /// before runApp so that _pendingAction is populated for cold launches.
  Future<void> initializeAndCheckLaunch() async {
    if (Platform.isMacOS) return;
    await _initLocalNotifications();
    try {
      final details = await _plugin?.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp == true) {
        final action = _parsePayload(details?.notificationResponse?.payload);
        if (action != null) _pendingAction = action;
      }
    } catch (_) {}
  }

  Future<void> _doInitLocalNotifications() async {
    // timezone data is only needed for zonedSchedule (Android/iOS/Windows).
    if (!Platform.isLinux) {
      tz_data.initializeTimeZones();
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Not const: DarwinNotificationAction.plain is a factory constructor,
    // so the notificationCategories list below isn't a compile-time constant.
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(
          mailCategoryIdentifier,
          actions: [
            DarwinNotificationAction.plain(dismissActionId, 'Dismiss'),
            DarwinNotificationAction.plain(markReadActionId, 'Mark Read'),
            DarwinNotificationAction.plain(
              deleteActionId,
              'Delete',
              options: {DarwinNotificationActionOption.destructive},
            ),
          ],
        ),
      ],
    );
    const linux = LinuxInitializationSettings(defaultActionName: 'View');
    const windows = WindowsInitializationSettings(
      appName: 'NightMail',
      appUserModelId: 'au.com.sharpblue.NightMail',
      guid: '6e452e7a-3c45-4b9e-8f1d-2a7b8c3d9e1f',
    );

    // Unawaited from the constructor (see _initLocalNotifications), so a
    // failure here — no platform plugin registered, as under `flutter test`,
    // where nothing invokes GeneratedPluginRegistrant — would otherwise
    // surface as an unhandled async error with no caller to catch it.
    try {
      await _plugin?.initialize(
        settings: InitializationSettings(
          android: android,
          iOS: darwin,
          linux: linux,
          windows: windows,
        ),
        onDidReceiveNotificationResponse: _onNotificationResponse,
        onDidReceiveBackgroundNotificationResponse:
            _onBackgroundNotificationResponse,
      );
    } catch (e) {
      debugPrint('NotificationService._doInitLocalNotifications failed: $e');
    }
  }

  /// Hands a reminder change made in a sub-window to the main window, which is
  /// the only engine that may talk to the OS scheduler (see [_plugin]).
  ///
  /// Returns true when the caller should stop — the change is the main window's
  /// to apply now. Its reconcilers re-derive the correct schedule by *fetching*
  /// the account, so the change has to be committed to the server before this
  /// is called; every current caller awaits its API call first.
  ///
  /// macOS never gets here: its reminders go through a bespoke
  /// UNUserNotificationCenter channel that is process-wide and works from any
  /// engine, so sub-windows there schedule directly.
  Future<bool> _handedToMainWindow() async {
    if (AppWindow.isMain) return false;
    await ReminderReconcileChannel.requestReconcile();
    return true;
  }

  void _onNotificationResponse(NotificationResponse details) {
    final actionId = details.actionId;
    if (actionId == markReadActionId || actionId == deleteActionId) {
      final action = _parsePayload(details.payload);
      if (action is OpenEmailAction) {
        unawaited(handleMailAction(
          actionId: actionId!,
          emailId: action.emailId,
          accountId: action.accountId,
        ));
      }
      return;
    }
    if (actionId == dismissActionId) return; // OS already removes it.

    final action = _parsePayload(details.payload);
    if (action == null) return;
    _setAction(action);
  }

  /// What Mark Read/Delete actually do, called from every native side that
  /// can raise one of the mail category's actions: this class's own iOS/
  /// Android/Linux/Windows foreground and background handlers above, and
  /// macOS's native channel (`_handleNativeCall` below). One place, so
  /// "what does Mark Read/Delete mean" can't drift between platforms.
  ///
  /// Deliberately routes through the same use cases the rest of the app
  /// uses (not a bespoke notification-only mutation): that's what gives
  /// this the outbox's offline durability and optimistic cache update for
  /// free. [accountId] is passed explicitly rather than relying on
  /// AccountManager.activeAccount — the account a notification is for is
  /// routinely not the foreground account, especially from a background
  /// isolate where there is no foreground at all.
  Future<void> handleMailAction({
    required String actionId,
    required String emailId,
    required String accountId,
  }) async {
    if (actionId == markReadActionId) {
      await sl<MarkEmailAsRead>()(MarkEmailAsReadParams(
        id: emailId,
        isRead: true,
        accountId: accountId,
      ));
    } else if (actionId == deleteActionId) {
      await sl<DeleteEmail>()(
        DeleteEmailParams(id: emailId, accountId: accountId),
      );
    }
  }

  NotificationAction? _parsePayload(String? payload) {
    if (payload == null) return null;
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final type = json['type'] as String?;
      if (type == 'email') {
        final emailId = json['emailId'] as String?;
        final accountId = json['accountId'] as String?;
        if (emailId != null && accountId != null) {
          return OpenEmailAction(emailId: emailId, accountId: accountId);
        }
      } else if (type == 'reminder') {
        final eventId = json['eventId'] as String?;
        final startIso = json['startIso'] as String?;
        if (eventId != null) {
          return OpenCalendarEventAction(eventId: eventId, startIso: startIso);
        }
      } else if (type == 'task') {
        final taskId = json['taskId'] as String?;
        final listId = json['listId'] as String?;
        final accountId = json['accountId'] as String?;
        if (taskId != null && listId != null && accountId != null) {
          return OpenTaskAction(
            taskId: taskId,
            listId: listId,
            accountId: accountId,
          );
        }
      } else if (type == 'tasksSummary') {
        final accountId = json['accountId'] as String?;
        if (accountId != null) return OpenTasksAction(accountId: accountId);
      }
    } catch (_) {}
    return null;
  }

  void _setAction(NotificationAction action) {
    if (_actionController.hasListener) {
      _actionController.add(action);
    } else {
      _pendingAction = action;
    }
  }

  NotificationAction? takePendingAction() {
    final action = _pendingAction;
    _pendingAction = null;
    return action;
  }

  // macOS only: called from Swift via the native channel.
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'showReminderPopup':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        await _openReminderPopup(
          eventId: args['eventId'] as String? ?? '',
          eventTitle: args['eventTitle'] as String? ?? '',
          startIso: args['startIso'] as String?,
          minutesUntilStart: args['minutesUntilStart'] as int?,
        );
      case 'openEmail':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final emailId = args['emailId'] as String?;
        final accountId = args['accountId'] as String?;
        if (emailId != null && accountId != null) {
          _setAction(OpenEmailAction(emailId: emailId, accountId: accountId));
        }
      case 'markEmailRead':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final emailId = args['emailId'] as String?;
        final accountId = args['accountId'] as String?;
        if (emailId != null && accountId != null) {
          await handleMailAction(
            actionId: markReadActionId,
            emailId: emailId,
            accountId: accountId,
          );
        }
      case 'deleteEmailNotification':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final emailId = args['emailId'] as String?;
        final accountId = args['accountId'] as String?;
        if (emailId != null && accountId != null) {
          await handleMailAction(
            actionId: deleteActionId,
            emailId: emailId,
            accountId: accountId,
          );
        }
      case 'openCalendarEvent':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final eventId = args['eventId'] as String?;
        final startIso = args['startIso'] as String?;
        if (eventId != null) {
          _setAction(
              OpenCalendarEventAction(eventId: eventId, startIso: startIso));
        }
      case 'openTask':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final taskId = args['taskId'] as String?;
        final listId = args['listId'] as String?;
        final accountId = args['accountId'] as String?;
        if (taskId != null && listId != null && accountId != null) {
          _setAction(OpenTaskAction(
            taskId: taskId,
            listId: listId,
            accountId: accountId,
          ));
        }
      case 'openTasks':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final accountId = args['accountId'] as String?;
        if (accountId != null) {
          _setAction(OpenTasksAction(accountId: accountId));
        }
    }
  }

  Future<void> _openReminderPopup({
    required String eventId,
    required String eventTitle,
    String? startIso,
    int? minutesUntilStart,
  }) async {
    await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({
          'type': 'eventReminder',
          'eventId': eventId,
          'eventTitle': eventTitle,
          if (startIso != null) 'startIso': startIso,
          if (minutesUntilStart != null) 'minutesUntilStart': minutesUntilStart,
        }),
      ),
    );
  }

  /// Shows a per-email notification. On macOS goes via the native channel;
  /// on iOS/Android uses flutter_local_notifications directly. Also fires
  /// on Windows/Linux from the Graph delta-sync path in `MailPollerCubit`,
  /// which has per-email detail (subject/sender) available.
  Future<void> showEmailNotification({
    required String emailId,
    required String accountId,
    required String subject,
    required String senderName,
    required String accountLabel,
  }) async {
    final title = subject.isNotEmpty ? subject : '(No Subject)';
    final body = senderName.isNotEmpty ? '$senderName · $accountLabel' : accountLabel;
    final notifId = emailId.hashCode.abs() % 0x7FFFFFFF;

    if (Platform.isMacOS) {
      try {
        await _macChannel.invokeMethod<void>('showMailNotification', {
          'id': emailId,
          'title': title,
          'body': body,
          'emailId': emailId,
          'accountId': accountId,
        });
      } catch (_) {}
      return;
    }

    await _initLocalNotifications();
    final payload = jsonEncode({
      'type': 'email',
      'emailId': emailId,
      'accountId': accountId,
    });
    try {
      await _plugin?.show(
        id: notifId,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'new_mail',
            'New Mail',
            channelDescription: 'Notifies when new mail arrives',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(
            sound: 'default',
            categoryIdentifier: mailCategoryIdentifier,
          ),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('NotificationService.showEmailNotification failed: $e');
    }
  }

  /// Shows an aggregate "N new emails" alert for account types whose poll
  /// path only knows an unread *count*, not individual messages (Gmail/IMAP,
  /// and Microsoft's first-run bootstrap poll before a delta token exists) —
  /// unlike `showEmailNotification`'s per-message detail, used once a Graph
  /// account has a delta token and upserted message objects to work with.
  ///
  /// Windows/Linux only: those platforms have no OS-level badge equivalent
  /// (macOS dock badge, mobile background isolate) to fall back on, so the
  /// foreground `MailPollerCubit` raises this itself. macOS is not supported
  /// here: its reminders go through a bespoke UNUserNotificationCenter
  /// channel (_macChannel) instead of this plugin, which is never
  /// initialized on macOS.
  Future<void> showNewMailNotification({
    required String accountLabel,
    required int newCount,
  }) async {
    if (Platform.isMacOS) return;
    await _initLocalNotifications();
    try {
      await _plugin?.show(
        id: accountLabel.hashCode.abs() % 0x7FFFFFFF,
        title: newCount == 1 ? 'New email' : '$newCount new emails',
        body: accountLabel,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'new_mail',
            'New Mail',
            channelDescription: 'Notifies when new mail arrives',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(sound: 'default'),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('NotificationService.showNewMailNotification failed: $e');
    }
  }

  Future<bool> requestPermission() async {
    if (Platform.isMacOS) {
      try {
        final result =
            await _macChannel.invokeMethod<String>('requestPermission');
        return result == 'granted';
      } catch (_) {
        return false;
      }
    }
    if (Platform.isAndroid) {
      final impl = _plugin?.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await impl?.requestNotificationsPermission() ?? false;
    }
    if (Platform.isIOS) {
      final impl = _plugin?.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await impl?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    return true;
  }

  /// Schedules the whole reminder series for one meeting: an alert at
  /// [reminderMinutes] before the start, then a countdown alert every
  /// [_followUpStepMinutes] minutes as it approaches, ending with a "Starting
  /// now" alert at the start itself.
  ///
  /// Offsets whose moment has already gone by are skipped individually rather
  /// than abandoning the series, so a meeting brought forward to inside its own
  /// lead time still gets the rest of the countdown and the final alert.
  ///
  /// Callers keep treating a reminder as one thing: they pass the event's lead
  /// time here and [cancelEventReminder] clears every alert in the series
  /// without being told which offsets are live.
  Future<void> scheduleEventReminder({
    required String accountId,
    required String eventId,
    required String eventTitle,
    required DateTime startUtc,
    required int reminderMinutes,
    String? startIso,
  }) async {
    // Hoisted out of the loop: a sub-window hands the whole series to the main
    // window at once, not one alert at a time.
    if (!Platform.isMacOS && await _handedToMainWindow()) return;

    final now = DateTime.now().toUtc();
    final iso = startIso ?? startUtc.toIso8601String();
    final base = _key(accountId, eventId);
    final offsets = reminderOffsets(reminderMinutes);
    // Every alert in the series taps through to the same event.
    final payload = jsonEncode({
      'type': 'reminder',
      'eventId': eventId,
      'startIso': iso,
    });

    for (var i = 0; i < offsets.length; i++) {
      final offset = offsets[i];
      final triggerTime = startUtc.subtract(Duration(minutes: offset));
      if (!triggerTime.isAfter(now)) continue;

      // The first alert keeps the bare [_key] this method has always used, so
      // rescheduling supersedes (rather than doubles up on) a reminder left
      // pending by a build that only ever scheduled one alert per event.
      final key = i == 0 ? base : _followUpKey(base, offset);
      final body = _countdownLabel(offset);
      // The macOS reminder popup is NightMail's own window, not an OS banner,
      // so only the two alerts worth interrupting for get one: the first (the
      // lead-time warning the user asked for) and the last (the meeting is
      // starting). The countdown in between arrives as a banner, which is what
      // every other platform shows throughout.
      final popup = i == 0 || offset == 0;

      if (Platform.isMacOS) {
        try {
          await _macChannel.invokeMethod<void>('scheduleReminder', {
            'id': key,
            'title': eventTitle,
            'body': body,
            'triggerMs': triggerTime.millisecondsSinceEpoch,
            'startIso': iso,
            'eventId': eventId,
            'minutesUntilStart': offset,
            'popup': popup,
          });
        } catch (_) {}
        continue;
      }

      if (Platform.isLinux) {
        _scheduleLinux(
          key: key,
          eventTitle: eventTitle,
          triggerTime: triggerTime,
          body: body,
        );
        continue;
      }

      try {
        final scheduled = tz.TZDateTime.fromMillisecondsSinceEpoch(
          tz.UTC,
          triggerTime.millisecondsSinceEpoch,
        );
        await _plugin?.zonedSchedule(
          id: _idFor(key),
          title: eventTitle,
          body: body,
          scheduledDate: scheduled,
          payload: payload,
          notificationDetails: _reminderDetails(),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      } catch (e) {
        debugPrint('NotificationService.scheduleEventReminder failed: $e');
      }
    }
  }

  void _scheduleLinux({
    required String key,
    required String eventTitle,
    required DateTime triggerTime,
    required String body,
  }) {
    _linuxTimers[key]?.cancel();
    final delay = triggerTime.toUtc().difference(DateTime.now().toUtc());
    _linuxTimers[key] = Timer(delay, () {
      _linuxTimers.remove(key);
      _plugin?.show(
        id: _idFor(key),
        title: eventTitle,
        body: body,
        notificationDetails: const NotificationDetails(
          linux: LinuxNotificationDetails(),
        ),
      );
    });
  }

  /// Clears every alert in an event's reminder series — the lead-time one and
  /// each follow-up offset a countdown can use, whether or not this run
  /// scheduled them.
  ///
  /// Cancelling ids the OS has never seen is a no-op everywhere, and it is what
  /// lets the offsets stay a private detail: neither the caller nor the
  /// persisted schedule has to remember which lead time built the series, and a
  /// reminder left pending by a build that scheduled a single alert per event
  /// is cleared along with it.
  Future<void> cancelEventReminder({
    required String accountId,
    required String eventId,
  }) async {
    final base = _key(accountId, eventId);
    final keys = [
      base,
      for (final offset in _followUpOffsets) _followUpKey(base, offset),
    ];

    if (Platform.isMacOS) {
      // One call for the set: UNUserNotificationCenter removes pending
      // requests by identifier list, so a series costs the same round trip a
      // single alert used to.
      try {
        await _macChannel.invokeMethod<void>('cancelReminder', {'ids': keys});
      } catch (_) {}
      return;
    }
    if (await _handedToMainWindow()) return;
    for (final key in keys) {
      _linuxTimers.remove(key)?.cancel();
      await _plugin?.cancel(id: _idFor(key));
    }
  }

  /// Whether a future notification handed to [scheduleTaskReminder] is held by
  /// an OS scheduler that keeps firing after NightMail exits.
  ///
  /// True everywhere except Linux, where there is no scheduling API in the
  /// notification spec and reminders are held by an in-process [Timer] that
  /// dies with the app. [TaskReminderService] uses this to decide whether a
  /// trigger that has already passed was delivered by the OS or was silently
  /// dropped and needs re-raising on the next reconcile.
  bool get osRetainsSchedule => !Platform.isLinux;

  /// How many alerts [scheduleEventReminder] would hand the OS for one meeting
  /// right now: the series minus the offsets already gone by, which that method
  /// skips individually.
  ///
  /// Static so a caller budgeting a whole reconcile pass against the OS's
  /// per-app ceiling counts what will actually be queued rather than what the
  /// series would be in the abstract — and so a mocked [NotificationService]
  /// cannot answer with a dummy that silently disables the budget.
  static int alertCountFor({
    required DateTime startUtc,
    required int reminderMinutes,
    required DateTime now,
  }) =>
      reminderOffsets(reminderMinutes)
          .where((offset) =>
              startUtc.subtract(Duration(minutes: offset)).isAfter(now))
          .length;

  /// What the OS is *still holding*, as opposed to what it was asked for.
  ///
  /// Null where that cannot be established — a sub-window (which owns no
  /// plugin), Linux (whose reminders are in-process timers that die with the
  /// app, already covered by [osRetainsSchedule]), or a platform call that
  /// failed. A null answer means "nothing learned", never "nothing pending":
  /// callers must fall back to trusting their own records rather than treating
  /// every reminder as missing and rescheduling the lot.
  Future<PendingReminders?> pendingReminders() async {
    if (Platform.isMacOS) {
      try {
        final ids = await _macChannel
            .invokeMethod<List<dynamic>>('pendingReminderIds', {'kind': 'event'});
        if (ids == null) return null;
        return PendingReminders._keys(ids.cast<String>().toSet());
      } catch (e) {
        debugPrint('NotificationService.pendingReminders failed: $e');
        return null;
      }
    }
    if (Platform.isLinux) return null;
    final plugin = _plugin;
    if (plugin == null) return null;
    try {
      await _initLocalNotifications();
      final requests = await plugin.pendingNotificationRequests();
      return PendingReminders._ids(requests.map((r) => r.id).toSet());
    } catch (e) {
      debugPrint('NotificationService.pendingReminders failed: $e');
      return null;
    }
  }

  /// Shows a "task is due" alert immediately. Used for tasks that fell due
  /// while NightMail wasn't running (or on Linux, where the in-process timer
  /// didn't survive), so the user still learns about it at the next poll.
  Future<void> showTaskDueNotification({
    required String accountId,
    required String listId,
    required String taskId,
    required String title,
    required String body,
  }) async {
    if (Platform.isMacOS) {
      try {
        await _macChannel.invokeMethod<void>('showTaskNotification', {
          'id': _taskKey(accountId, taskId),
          'title': title,
          'body': body,
          'taskId': taskId,
          'listId': listId,
          'accountId': accountId,
        });
      } catch (_) {}
      return;
    }

    await _initLocalNotifications();
    try {
      await _plugin?.show(
        id: _taskNotifId(accountId, taskId),
        title: title,
        body: body,
        payload: _taskPayload(
            accountId: accountId, listId: listId, taskId: taskId),
        notificationDetails: _taskDetails(),
      );
    } catch (e) {
      debugPrint('NotificationService.showTaskDueNotification failed: $e');
    }
  }

  /// Shows one aggregate alert standing in for [count] tasks that are due,
  /// used when announcing them one by one would be a wall of banners.
  Future<void> showTasksDueSummaryNotification({
    required String accountId,
    required int count,
    required String accountLabel,
  }) async {
    final title = '$count tasks are due';
    if (Platform.isMacOS) {
      try {
        await _macChannel.invokeMethod<void>('showTasksSummaryNotification', {
          'id': 'tasks::$accountId',
          'title': title,
          'body': accountLabel,
          'accountId': accountId,
        });
      } catch (_) {}
      return;
    }

    await _initLocalNotifications();
    try {
      await _plugin?.show(
        id: 'tasks::$accountId'.hashCode.abs() % 0x7FFFFFFF,
        title: title,
        body: accountLabel,
        payload: jsonEncode({'type': 'tasksSummary', 'accountId': accountId}),
        notificationDetails: _taskDetails(),
      );
    } catch (e) {
      debugPrint(
          'NotificationService.showTasksDueSummaryNotification failed: $e');
    }
  }

  /// Schedules a "task is due" alert for [triggerUtc]. A trigger already in
  /// the past is ignored — callers show it immediately via
  /// [showTaskDueNotification] instead.
  Future<void> scheduleTaskReminder({
    required String accountId,
    required String listId,
    required String taskId,
    required String title,
    required String body,
    required DateTime triggerUtc,
  }) async {
    if (!triggerUtc.isAfter(DateTime.now().toUtc())) return;

    final key = _taskKey(accountId, taskId);

    if (Platform.isMacOS) {
      try {
        await _macChannel.invokeMethod<void>('scheduleReminder', {
          'id': key,
          'kind': 'task',
          'title': title,
          'body': body,
          'triggerMs': triggerUtc.millisecondsSinceEpoch,
          'taskId': taskId,
          'listId': listId,
          'accountId': accountId,
        });
      } catch (_) {}
      return;
    }

    if (await _handedToMainWindow()) return;

    if (Platform.isLinux) {
      _linuxTimers[key]?.cancel();
      final delay = triggerUtc.difference(DateTime.now().toUtc());
      _linuxTimers[key] = Timer(delay, () {
        _linuxTimers.remove(key);
        _plugin?.show(
          id: _taskNotifId(accountId, taskId),
          title: title,
          body: body,
          notificationDetails: const NotificationDetails(
            linux: LinuxNotificationDetails(),
          ),
        );
      });
      return;
    }

    await _initLocalNotifications();
    try {
      final scheduled = tz.TZDateTime.fromMillisecondsSinceEpoch(
        tz.UTC,
        triggerUtc.millisecondsSinceEpoch,
      );
      await _plugin?.zonedSchedule(
        id: _taskNotifId(accountId, taskId),
        title: title,
        body: body,
        scheduledDate: scheduled,
        payload: _taskPayload(
            accountId: accountId, listId: listId, taskId: taskId),
        notificationDetails: _taskDetails(),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    } catch (e) {
      debugPrint('NotificationService.scheduleTaskReminder failed: $e');
    }
  }

  Future<void> cancelTaskReminder({
    required String accountId,
    required String taskId,
  }) async {
    final key = _taskKey(accountId, taskId);
    if (Platform.isMacOS) {
      try {
        await _macChannel
            .invokeMethod<void>('cancelReminder', {'id': key, 'kind': 'task'});
      } catch (_) {}
      return;
    }
    if (await _handedToMainWindow()) return;
    _linuxTimers.remove(key)?.cancel();
    await _plugin?.cancel(id: _taskNotifId(accountId, taskId));
  }

  static String _taskPayload({
    required String accountId,
    required String listId,
    required String taskId,
  }) =>
      jsonEncode({
        'type': 'task',
        'taskId': taskId,
        'listId': listId,
        'accountId': accountId,
      });

  static NotificationDetails _taskDetails() => const NotificationDetails(
        android: AndroidNotificationDetails(
          'task_due',
          'Task Reminders',
          channelDescription: 'Reminders for tasks that are due',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(sound: 'default'),
        linux: LinuxNotificationDetails(),
        windows: WindowsNotificationDetails(),
      );

  static NotificationDetails _reminderDetails() => const NotificationDetails(
        android: AndroidNotificationDetails(
          'event_reminders',
          'Event Reminders',
          channelDescription: 'Reminders for upcoming calendar events',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(sound: 'default'),
        linux: LinuxNotificationDetails(),
        windows: WindowsNotificationDetails(),
      );

  /// How far apart the follow-up alerts in a reminder series are.
  static const _followUpStepMinutes = 5;

  /// How long before the start the countdown begins.
  ///
  /// A lead time of 15 minutes or less is countdown the whole way (the default
  /// 15-minute reminder alerts at 15, 10, 5 and 0). A longer one gets the alert
  /// it asked for, then nothing until the last quarter hour — the countdown is
  /// there to walk someone into a meeting, not to nag them through the hour
  /// before it.
  ///
  /// The bound also keeps the series affordable. The step is fixed, so a lead
  /// time of a day — an option in the reminder dropdown — would otherwise
  /// expand to 289 alerts for one meeting, and iOS keeps only the 64 soonest
  /// pending notifications per app before silently discarding the rest. At five
  /// alerts per meeting no realistic calendar comes near that.
  static const _followUpWindowMinutes = 15;

  /// Every offset a follow-up alert can use, furthest from the start first.
  ///
  /// Fixed rather than derived per event so [cancelEventReminder] can clear a
  /// series knowing only the account and event ids.
  static final List<int> _followUpOffsets = [
    for (var m = _followUpWindowMinutes; m >= 0; m -= _followUpStepMinutes) m,
  ];

  /// The offsets, in minutes before the start, at which the reminder series for
  /// a meeting with a [reminderMinutes] lead time fires: the lead-time alert
  /// first, then the countdown, always ending at 0 — the final "Starting now".
  @visibleForTesting
  static List<int> reminderOffsets(int reminderMinutes) => [
        if (reminderMinutes > 0) reminderMinutes,
        for (final offset in _followUpOffsets)
          if (offset < reminderMinutes) offset,
        if (reminderMinutes <= 0) 0,
      ];

  static String _key(String accountId, String eventId) => '$accountId::$eventId';

  static String _followUpKey(String baseKey, int offsetMinutes) =>
      '$baseKey::$offsetMinutes';

  static int _idFor(String key) => key.hashCode.abs() % 0x7FFFFFFF;

  // Deliberately a different string shape from _key so a task and an event
  // sharing an id can never collide in the notification-id space.
  static String _taskKey(String accountId, String taskId) =>
      'task::$accountId::$taskId';

  static int _taskNotifId(String accountId, String taskId) =>
      _idFor(_taskKey(accountId, taskId));

  static String _countdownLabel(int minutesUntilStart) => minutesUntilStart <= 0
      ? 'Starting now'
      : 'Starting in ${_minutesLabel(minutesUntilStart)}';

  static String _minutesLabel(int minutes) {
    if (minutes < 60) return '$minutes minute${minutes == 1 ? '' : 's'}';
    final h = minutes ~/ 60;
    return '$h hour${h == 1 ? '' : 's'}';
  }
}

/// A snapshot of the alerts the OS is still holding, taken once per reconcile
/// pass by [NotificationService.pendingReminders].
///
/// Scheduling reports success for a request the system silently discarded —
/// every platform here caps how many pending alerts one app may hold, and
/// NightMail's countdown series multiplies one meeting into up to five — so a
/// row in `scheduled_reminders` records what was *asked for*, not what is
/// queued. This is how a caller tells the two apart, and it covers the other
/// way a schedule goes missing too: anything cleared behind the app's back
/// while it was not running.
///
/// Two shapes because the platforms address an alert differently: macOS holds
/// the keys verbatim, everything else holds the hashed integer ids
/// [NotificationService._idFor] derives from them. Which one is in hand is an
/// implementation detail of the platform, not of the caller.
class PendingReminders {
  const PendingReminders._keys(Set<String> keys)
      : _keys = keys,
        _ids = null;

  const PendingReminders._ids(Set<int> ids)
      : _keys = null,
        _ids = ids;

  /// The macOS shape, built directly. The key format is a contract with
  /// `scheduleEventReminder` and with the `<kind>_reminder_` prefix the Swift
  /// side strips, so it is worth pinning from a test.
  @visibleForTesting
  const PendingReminders.fromKeys(Set<String> keys)
      : _keys = keys,
        _ids = null;

  final Set<String>? _keys;
  final Set<int>? _ids;

  /// Whether every alert that *should* still be pending for this meeting is.
  ///
  /// Offsets already gone by are not expected — `scheduleEventReminder` skips
  /// them — so a meeting mid-countdown is not judged missing over the alerts it
  /// has already delivered. A series with nothing left to fire is held
  /// vacuously, which is what stops a meeting inside its own lead time being
  /// rescheduled on every pass for the rest of its life.
  bool holdsSeries({
    required String accountId,
    required String eventId,
    required DateTime startUtc,
    required int reminderMinutes,
    required DateTime now,
  }) {
    final base = NotificationService._key(accountId, eventId);
    final offsets = NotificationService.reminderOffsets(reminderMinutes);
    for (var i = 0; i < offsets.length; i++) {
      final offset = offsets[i];
      if (!startUtc.subtract(Duration(minutes: offset)).isAfter(now)) continue;
      // The first alert keeps the bare key, exactly as scheduling assigns it.
      final key =
          i == 0 ? base : NotificationService._followUpKey(base, offset);
      final keys = _keys;
      final held = keys != null
          ? keys.contains(key)
          : _ids!.contains(NotificationService._idFor(key));
      if (!held) return false;
    }
    return true;
  }
}
