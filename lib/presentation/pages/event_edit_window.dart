import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/calendar_event_attendee.dart';
import '../../domain/entities/calendar_recurrence.dart';
import '../../domain/usecases/create_calendar_event.dart';
import '../../domain/usecases/update_calendar_event.dart';
import '../../injection_container.dart';
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

    return BlocProvider<ThemeCubit>(
      create: (_) => sl<ThemeCubit>()..load(),
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
      location: raw['location'] as String?,
      bodyPreview: raw['bodyPreview'] as String?,
      timezone: raw['timezone'] as String?,
      attendees: _parseAttendees(raw['attendees'] as List<dynamic>?),
      recurrence: _parseRecurrence(raw['recurrence'] as Map<String, dynamic>?),
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

class _EventEditWindowPage extends StatelessWidget {
  const _EventEditWindowPage({this.event, this.initialStart, this.accountId});

  final CalendarEvent? event;
  final DateTime? initialStart;
  final String? accountId;

  void _close() => windowManager.close();

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => EventEditBloc(
        createCalendarEvent: sl<CreateCalendarEvent>(),
        updateCalendarEvent: sl<UpdateCalendarEvent>(),
      ),
      child: Scaffold(
        body: BlocListener<EventEditBloc, EventEditState>(
          listener: (context, state) async {
            if (state is EventEditSaved) {
              await _kCalendarRefreshChannel.invokeMethod('notifyEventSaved');
              _close();
            } else if (state is EventEditError) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(state.message),
                backgroundColor: Colors.red.shade700,
              ));
            }
          },
          child: EventEditForm(
            event: event,
            initialStart: initialStart,
            accountId: accountId,
            onClose: _close,
            onTitleChanged: (title) => windowManager.setTitle(title),
          ),
        ),
      ),
    );
  }
}
