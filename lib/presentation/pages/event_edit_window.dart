import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/settings/window_bounds_service.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/calendar_event_attendee.dart';
import '../../domain/entities/calendar_recurrence.dart';
import '../../domain/usecases/check_attendees_availability.dart';
import '../../domain/usecases/get_meeting_rooms.dart';
import '../../domain/usecases/create_calendar_event.dart';
import '../../domain/usecases/update_calendar_event.dart';
import '../../infrastructure/notifications/notification_service.dart';
import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/event_edit/event_edit_bloc.dart';
import '../blocs/event_edit/event_edit_state.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';
import '../widgets/event_edit_dialog.dart';

const _kCalendarRefreshChannel =
    MethodChannel('au.com.sharpblue.nightmail/calendar_refresh');

class EventEditWindowApp extends StatelessWidget {
  const EventEditWindowApp({
    super.key,
    required this.windowId,
    required this.arguments,
  });

  final String windowId;
  final Map<String, dynamic> arguments;

  static final _darkTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C83FD),
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
  );

  static final _lightTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C83FD),
    ),
    useMaterial3: true,
  );

  @override
  Widget build(BuildContext context) {
    final event = _parseEvent(arguments['event'] as Map<String, dynamic>?);
    final initialStartStr = arguments['initialStart'] as String?;
    final initialStart =
        initialStartStr != null ? DateTime.parse(initialStartStr).toLocal() : null;
    final accountId = arguments['accountId'] as String?;
    final isO365Account = arguments['isO365Account'] as bool? ?? false;
    final isGmailAccount = arguments['isGmailAccount'] as bool? ?? false;

    return MultiBlocProvider(
      providers: [
        BlocProvider<ThemeCubit>(create: (_) => sl<ThemeCubit>()..load()),
        BlocProvider.value(value: sl<AccountCubit>()..initialize()),
      ],
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: switch (themeState.mode) {
              AppThemeMode.light => ThemeMode.light,
              AppThemeMode.dark => ThemeMode.dark,
              AppThemeMode.system => ThemeMode.system,
            },
            home: _EventEditWindowPage(
              event: event,
              initialStart: initialStart,
              accountId: accountId,
              isO365Account: isO365Account,
              isGmailAccount: isGmailAccount,
            ),
          );
        },
      ),
    );
  }

  static CalendarEvent? _parseEvent(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    return CalendarEvent(
      id: raw['id'] as String,
      subject: raw['subject'] as String? ?? '',
      start: DateTime.parse(raw['start'] as String).toLocal(),
      end: DateTime.parse(raw['end'] as String).toLocal(),
      isAllDay: raw['isAllDay'] as bool? ?? false,
      isOrganizer: raw['isOrganizer'] as bool? ?? false,
      location: raw['location'] as String?,
      onlineMeetingUrl: raw['onlineMeetingUrl'] as String?,
      bodyPreview: raw['bodyPreview'] as String?,
      timezone: raw['timezone'] as String?,
      attendees: _parseAttendees(raw['attendees'] as List<dynamic>?),
      recurrence: _parseRecurrence(raw['recurrence'] as Map<String, dynamic>?),
      reminderMinutes: raw['reminderMinutes'] as int?,
      seriesMasterId: raw['seriesMasterId'] as String?,
    );
  }

  static List<CalendarEventAttendee> _parseAttendees(List<dynamic>? raw) {
    if (raw == null) return const [];
    return raw.cast<Map<String, dynamic>>().map((a) {
      final status = switch ((a['responseStatus'] as String?)?.toLowerCase()) {
        'accepted' => AttendeeResponseStatus.accepted,
        'tentative' => AttendeeResponseStatus.tentative,
        'declined' => AttendeeResponseStatus.declined,
        _ => AttendeeResponseStatus.none,
      };
      return CalendarEventAttendee(
        email: a['email'] as String,
        displayName: a['displayName'] as String?,
        responseStatus: status,
        // Written by EventEditDialog._eventToArgs only when true. Without it the
        // form would put this meeting's booked rooms in the Guests field and
        // re-invite them as people on save.
        isResource: a['isResource'] as bool? ?? false,
      );
    }).toList();
  }

  static CalendarRecurrence? _parseRecurrence(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    final freq = switch ((raw['frequency'] as String?)?.toLowerCase()) {
      'daily' => RecurrenceFrequency.daily,
      'weekly' => RecurrenceFrequency.weekly,
      'monthly' => RecurrenceFrequency.monthly,
      'yearly' => RecurrenceFrequency.yearly,
      _ => RecurrenceFrequency.daily,
    };
    final endDateStr = raw['endDate'] as String?;
    final rawDays = raw['daysOfWeek'] as List<dynamic>?;
    return CalendarRecurrence(
      frequency: freq,
      interval: raw['interval'] as int? ?? 1,
      daysOfWeek: rawDays?.cast<int>(),
      endDate: endDateStr != null ? DateTime.parse(endDateStr) : null,
      count: raw['count'] as int?,
    );
  }
}

class _EventEditWindowPage extends StatefulWidget {
  const _EventEditWindowPage({
    this.event,
    this.initialStart,
    this.accountId,
    this.isO365Account = false,
    this.isGmailAccount = false,
  });

  final CalendarEvent? event;
  final DateTime? initialStart;
  final String? accountId;
  final bool isO365Account;
  final bool isGmailAccount;

  @override
  State<_EventEditWindowPage> createState() => _EventEditWindowPageState();
}

class _EventEditWindowPageState extends State<_EventEditWindowPage>
    with WindowListener {
  // Where the next event window opens. `main()` restores this before the window
  // is shown; from here on the window records every move and resize.
  Timer? _boundsDebounce;
  Timer? _suppressBoundsSaveTimer;

  // Suppress saves triggered by the compositor repositioning the window during
  // startup (Linux/Wayland places a window after it is mapped, firing
  // onWindowMove before the user has touched anything).
  bool _suppressBoundsSave = Platform.isLinux;

  // Whether the schedule pane is currently taking its share of the window
  // width — see [_withoutSchedulePane].
  bool _schedulePaneExpanded = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    if (_suppressBoundsSave) {
      _suppressBoundsSaveTimer =
          Timer(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        _suppressBoundsSave = false;
        // Record the position the compositor settled on, which may not be the
        // one that was asked for — otherwise the next window opens at bounds
        // Wayland has already refused once.
        _scheduleBoundsSave();
      });
    }
  }

  @override
  void dispose() {
    _boundsDebounce?.cancel();
    _suppressBoundsSaveTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  // ── Window geometry ──────────────────────────────────────────────────────
  //
  // The same debounce-and-save the main and compose windows use, against its
  // own file (`eventEditWindowBounds`), so an event window opens where the last
  // one was left rather than centred on the parent every time. Linux fires
  // resize/move continuously, which is what the debounce is for.

  /// The width worth remembering is the one *without* the schedule pane: the
  /// pane is added to the window when it opens and taken back when it closes,
  /// and it starts closed on the next window — where the form column is a fixed
  /// width and would leave the extra as empty space.
  Rect _withoutSchedulePane(Rect bounds) {
    if (!_schedulePaneExpanded) return bounds;
    return Rect.fromLTWH(
      bounds.left,
      bounds.top,
      math.max(kEventFormWidth, bounds.width - (kSchedulePaneWidth + 1)),
      bounds.height,
    );
  }

  void _scheduleBoundsSave() {
    if (_suppressBoundsSave) return;
    _boundsDebounce?.cancel();
    _boundsDebounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        // Maximize / full-screen have their own overrides below; saving plain
        // bounds here would record the maximized rect as a normal one.
        if (await windowManager.isMaximized()) return;
        if (await windowManager.isFullScreen()) return;
        await eventEditWindowBounds
            .saveBounds(_withoutSchedulePane(await windowManager.getBounds()));
      } catch (_) {}
    });
  }

  Future<void> _saveCurrentState() async {
    try {
      final fullScreen = await windowManager.isFullScreen();
      final maximized = await windowManager.isMaximized();
      await eventEditWindowBounds.saveBounds(
        _withoutSchedulePane(await windowManager.getBounds()),
        fullScreen: fullScreen,
        maximized: maximized,
      );
    } catch (_) {}
  }

  // macOS/Windows: fires once when the resize/move finishes.
  @override
  void onWindowResized() => _scheduleBoundsSave();

  @override
  void onWindowMoved() => _scheduleBoundsSave();

  // Linux: fires continuously during a resize/move — the debounce handles it.
  @override
  void onWindowResize() => _scheduleBoundsSave();

  @override
  void onWindowMove() => _scheduleBoundsSave();

  // Save at once on entering a special state, so a close straight afterwards
  // doesn't have to re-query a window that is already going away.
  @override
  void onWindowMaximize() => _saveCurrentState();

  @override
  void onWindowEnterFullScreen() => _saveCurrentState();

  /// The title-bar close button. This window sets no `setPreventClose` guard —
  /// it has no save-or-discard prompt to run and an un-closable window would be
  /// the worse trade — so the OS is already tearing it down and this is best
  /// effort. The debounced save is what actually covers this path: the geometry
  /// is already on disk 500 ms after the last move or resize.
  @override
  void onWindowClose() {
    _boundsDebounce?.cancel();
    _saveCurrentState();
  }

  /// Closing tears this engine down, so a pending debounced save would never
  /// fire — record the final geometry first. Timed out rather than merely
  /// try/caught: nothing about remembering where the window was is worth
  /// holding up a close the user asked for.
  Future<void> _close() async {
    _boundsDebounce?.cancel();
    try {
      await _saveCurrentState().timeout(const Duration(seconds: 1));
    } catch (_) {}
    await windowManager.close();
  }

  Future<void> _onSchedulePaneToggled(bool expanded) async {
    _schedulePaneExpanded = expanded;
    // Make room for the pane at its natural width. Anything the organizer
    // resizes the window to after that is the pane's to use — the form column
    // beside it stays fixed.
    const delta = kSchedulePaneWidth + 1; // + the divider
    final size = await windowManager.getSize();
    await windowManager.setSize(Size(
      expanded ? size.width + delta : size.width - delta,
      size.height,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => EventEditBloc(
        createCalendarEvent: sl<CreateCalendarEvent>(),
        updateCalendarEvent: sl<UpdateCalendarEvent>(),
        notificationService: sl<NotificationService>(),
        accountId: widget.accountId,
      ),
      child: Scaffold(
        body: BlocListener<EventEditBloc, EventEditState>(
          listener: (context, state) async {
            if (state is EventEditSaved) {
              await _kCalendarRefreshChannel.invokeMethod('notifyEventSaved');
              // Awaited so the window's final geometry is on disk before the
              // close takes this engine down with it.
              await _close();
            } else if (state is EventEditError) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(state.message),
                backgroundColor: Colors.red.shade700,
              ));
            }
          },
          child: EventEditForm(
            event: widget.event,
            initialStart: widget.initialStart,
            accountId: widget.accountId,
            isO365Account: widget.isO365Account,
            isGmailAccount: widget.isGmailAccount,
            onClose: _close,
            onTitleChanged: (title) => windowManager.setTitle(title),
            checkAttendeesAvailability: sl<CheckAttendeesAvailability>(),
            getMeetingRooms: sl<GetMeetingRooms>(),
            onSchedulePaneToggled: _onSchedulePaneToggled,
          ),
        ),
      ),
    );
  }
}
