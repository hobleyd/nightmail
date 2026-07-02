import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  static const _macChannel =
      MethodChannel('au.com.sharpblue.nightmail/notifications');

  // Singleton plugin instance shared across all calls.
  static final _localPlugin = FlutterLocalNotificationsPlugin();
  static bool _localInitialized = false;

  // Linux: flutter_local_notifications doesn't support zonedSchedule on Linux,
  // so we use in-process Dart timers and call show() when they fire.
  // Reminders only fire while the app is running on Linux.
  // Keyed by the same composite accountId::eventId string as _notifId.
  final _linuxTimers = <String, Timer>{};

  NotificationService() {
    if (Platform.isMacOS) {
      // macOS uses a native Swift channel → UNUserNotificationCenter.
      _macChannel.setMethodCallHandler(_handleNativeCall);
    } else {
      _initLocalNotifications();
    }
  }

  Future<void> _initLocalNotifications() async {
    if (_localInitialized) return;
    _localInitialized = true;

    // timezone data is only needed for zonedSchedule (Android/iOS/Windows).
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
      // Stable GUID for NightMail Windows notification activator (COM CLSID).
      guid: '6e452e7a-3c45-4b9e-8f1d-2a7b8c3d9e1f',
    );

    await _localPlugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: darwin,
        linux: linux,
        windows: windows,
      ),
    );
  }

  // macOS only: called from Swift via the native channel.
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'showReminderPopup') return;
    final args = Map<String, dynamic>.from(call.arguments as Map);
    await _openReminderPopup(
      eventId: args['eventId'] as String? ?? '',
      eventTitle: args['eventTitle'] as String? ?? '',
      startIso: args['startIso'] as String?,
    );
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

  /// Shows a local "new mail" alert. Used from the background mail-check
  /// isolate (Android WorkManager / iOS BGTaskScheduler) — those platforms'
  /// headless engines can reach flutter_local_notifications (it registers via
  /// GeneratedPluginRegistrant), unlike this app's ad-hoc native badge
  /// channel, which is only wired up on the foreground engine.
  Future<void> showNewMailNotification({
    required String accountLabel,
    required int newCount,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await _initLocalNotifications();
    try {
      await _localPlugin.show(
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
    // Linux and Windows do not require a runtime permission request.
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

    // Android, iOS, Windows: delegate to the OS scheduler so reminders fire
    // even when the app is closed.
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
        notificationDetails: _details(),
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

  static NotificationDetails _details() => const NotificationDetails(
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
