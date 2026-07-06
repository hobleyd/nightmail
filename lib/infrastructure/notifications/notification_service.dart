import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'notification_action.dart';

// Top-level callback — required for background isolate on Android when the
// app is killed and the user taps a notification.
@pragma('vm:entry-point')
void _onBackgroundNotificationResponse(NotificationResponse details) {
  // Background isolate: no DI, no UI. Nothing to do here — the action will
  // be picked up via getNotificationAppLaunchDetails when the app restarts.
}

class NotificationService {
  static const _macChannel =
      MethodChannel('au.com.sharpblue.nightmail/notifications');

  static final _localPlugin = FlutterLocalNotificationsPlugin();
  static bool _localInitialized = false;

  final _linuxTimers = <String, Timer>{};
  final _actionController = StreamController<NotificationAction>.broadcast();
  NotificationAction? _pendingAction;

  Stream<NotificationAction> get actions => _actionController.stream;

  // Stored so callers can await initialization before calling the plugin.
  Future<void>? _initFuture;

  NotificationService() {
    if (Platform.isMacOS) {
      _macChannel.setMethodCallHandler(_handleNativeCall);
    } else {
      _initFuture = _initLocalNotifications();
    }
  }

  /// Awaits plugin initialization and checks whether the app was launched by
  /// a notification tap (iOS/Android terminated-state). Call once in main()
  /// before runApp so that _pendingAction is populated for cold launches.
  Future<void> initializeAndCheckLaunch() async {
    if (Platform.isMacOS) return;
    await (_initFuture ?? _initLocalNotifications());
    try {
      final details = await _localPlugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp == true) {
        final action = _parsePayload(details?.notificationResponse?.payload);
        if (action != null) _pendingAction = action;
      }
    } catch (_) {}
  }

  Future<void> _initLocalNotifications() async {
    if (_localInitialized) return;
    _localInitialized = true;

    if (!Platform.isLinux) {
      tz_data.initializeTimeZones();
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const linux = LinuxInitializationSettings(defaultActionName: 'View');
    const windows = WindowsInitializationSettings(
      appName: 'NightMail',
      appUserModelId: 'au.com.sharpblue.NightMail',
      guid: '6e452e7a-3c45-4b9e-8f1d-2a7b8c3d9e1f',
    );

    await _localPlugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: darwin,
        linux: linux,
        windows: windows,
      ),
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          _onBackgroundNotificationResponse,
    );
  }

  void _onNotificationResponse(NotificationResponse details) {
    final action = _parsePayload(details.payload);
    if (action == null) return;
    _setAction(action);
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
        );
      case 'openEmail':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final emailId = args['emailId'] as String?;
        final accountId = args['accountId'] as String?;
        if (emailId != null && accountId != null) {
          _setAction(OpenEmailAction(emailId: emailId, accountId: accountId));
        }
      case 'openCalendarEvent':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final eventId = args['eventId'] as String?;
        final startIso = args['startIso'] as String?;
        if (eventId != null) {
          _setAction(
              OpenCalendarEventAction(eventId: eventId, startIso: startIso));
        }
    }
  }

  Future<void> _openReminderPopup({
    required String eventId,
    required String eventTitle,
    String? startIso,
  }) async {
    await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({
          'type': 'eventReminder',
          'eventId': eventId,
          'eventTitle': eventTitle,
          if (startIso != null) 'startIso': startIso,
        }),
      ),
    );
  }

  /// Shows a per-email notification. On macOS goes via the native channel;
  /// on iOS/Android uses flutter_local_notifications directly.
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
      await _localPlugin.show(
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
          iOS: DarwinNotificationDetails(sound: 'default'),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (_) {}
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
      final impl = _localPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await impl?.requestNotificationsPermission() ?? false;
    }
    if (Platform.isIOS) {
      final impl = _localPlugin.resolvePlatformSpecificImplementation<
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

  Future<void> scheduleEventReminder({
    required String accountId,
    required String eventId,
    required String eventTitle,
    required DateTime startUtc,
    required int reminderMinutes,
    String? startIso,
  }) async {
    final triggerTime = startUtc.subtract(Duration(minutes: reminderMinutes));
    if (!triggerTime.isAfter(DateTime.now().toUtc())) return;

    final key = _key(accountId, eventId);

    if (Platform.isMacOS) {
      try {
        await _macChannel.invokeMethod<void>('scheduleReminder', {
          'id': key,
          'title': eventTitle,
          'body': 'Starting in ${_minutesLabel(reminderMinutes)}',
          'triggerMs': triggerTime.millisecondsSinceEpoch,
          'startIso': startIso ?? startUtc.toIso8601String(),
          'eventId': eventId,
        });
      } catch (_) {}
      return;
    }

    if (Platform.isLinux) {
      _scheduleLinux(
        key: key,
        eventTitle: eventTitle,
        triggerTime: triggerTime,
        reminderMinutes: reminderMinutes,
      );
      return;
    }

    final payload = jsonEncode({
      'type': 'reminder',
      'eventId': eventId,
      'startIso': startIso ?? startUtc.toIso8601String(),
    });
    try {
      final scheduled = tz.TZDateTime.fromMillisecondsSinceEpoch(
        tz.UTC,
        triggerTime.millisecondsSinceEpoch,
      );
      await _localPlugin.zonedSchedule(
        id: _notifId(accountId, eventId),
        title: eventTitle,
        body: 'Starting in ${_minutesLabel(reminderMinutes)}',
        scheduledDate: scheduled,
        payload: payload,
        notificationDetails: _reminderDetails(),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    } catch (_) {}
  }

  void _scheduleLinux({
    required String key,
    required String eventTitle,
    required DateTime triggerTime,
    required int reminderMinutes,
  }) {
    _linuxTimers[key]?.cancel();
    final delay = triggerTime.toUtc().difference(DateTime.now().toUtc());
    _linuxTimers[key] = Timer(delay, () {
      _linuxTimers.remove(key);
      _localPlugin.show(
        id: key.hashCode.abs() % 0x7FFFFFFF,
        title: eventTitle,
        body: 'Starting in ${_minutesLabel(reminderMinutes)}',
        notificationDetails: const NotificationDetails(
          linux: LinuxNotificationDetails(),
        ),
      );
    });
  }

  Future<void> cancelEventReminder({
    required String accountId,
    required String eventId,
  }) async {
    final key = _key(accountId, eventId);
    if (Platform.isMacOS) {
      try {
        await _macChannel.invokeMethod<void>('cancelReminder', {'id': key});
      } catch (_) {}
      return;
    }
    _linuxTimers.remove(key)?.cancel();
    await _localPlugin.cancel(id: _notifId(accountId, eventId));
  }

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

  static String _key(String accountId, String eventId) => '$accountId::$eventId';

  static int _notifId(String accountId, String eventId) =>
      _key(accountId, eventId).hashCode.abs() % 0x7FFFFFFF;

  static String _minutesLabel(int minutes) {
    if (minutes < 60) return '$minutes minute${minutes == 1 ? '' : 's'}';
    final h = minutes ~/ 60;
    return '$h hour${h == 1 ? '' : 's'}';
  }
}
