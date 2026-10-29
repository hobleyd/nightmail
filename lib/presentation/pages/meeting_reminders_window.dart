import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/theme/app_colors.dart';
import '../../infrastructure/notifications/meeting_reminder_board.dart';
import '../../infrastructure/notifications/meeting_reminder_channel.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';
import '../widgets/meeting_reminder_list.dart';

/// The `type` the meeting-reminders window is created with.
const meetingRemindersWindowType = 'meetingReminders';

/// The single meeting-reminders window on macOS, Windows and Linux.
///
/// It holds no state of its own: the main window's [MeetingReminderBoard]
/// decides the rows and pushes them here, and a dismissal goes back to it.
class MeetingRemindersWindowApp extends StatelessWidget {
  const MeetingRemindersWindowApp({super.key, required this.arguments});

  final Map<String, dynamic> arguments;

  static const width = 360.0;

  /// The tallest the content may make the window; past it the list scrolls.
  static const maxContentHeight = 480.0;

  /// The size the window opens at for [rowCount] rows: a rough guess only,
  /// since fonts and the title bar vary by platform and setting. The page
  /// measures what it actually drew and fits the window to that on its first
  /// frame ([_MeetingRemindersPageState._fitToContent]).
  static Size initialSizeFor(int rowCount) =>
      Size(width, 160 + 72.0 * (rowCount.clamp(1, 4) - 1));

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
    return BlocProvider<ThemeCubit>(
      create: (_) => ThemeCubit()..load(),
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
            home: _MeetingRemindersPage(
              initialRows: MeetingReminderRow.listFromJson(arguments['rows']),
            ),
          );
        },
      ),
    );
  }
}

class _MeetingRemindersPage extends StatefulWidget {
  const _MeetingRemindersPage({required this.initialRows});

  final List<MeetingReminderRow> initialRows;

  @override
  State<_MeetingRemindersPage> createState() => _MeetingRemindersPageState();
}

class _MeetingRemindersPageState extends State<_MeetingRemindersPage> {
  late List<MeetingReminderRow> _rows = widget.initialRows;
  bool _closing = false;
  final _contentKey = GlobalKey();
  bool _fitScheduled = false;

  @override
  void initState() {
    super.initState();
    // The window usually opens while another app is in front, which is when a
    // reminder matters most and when an ordinary window lands behind it.
    unawaited(windowManager.setAlwaysOnTop(true).catchError((_) {}));
    unawaited(_connect());
  }

  /// Handler first, then the pull: whichever of a push and the snapshot lands
  /// last is at least as new as the other.
  Future<void> _connect() async {
    try {
      final controller = await WindowController.fromCurrentEngine();
      await controller.setWindowMethodHandler((MethodCall call) async {
        switch (call.method) {
          case MeetingReminderChannel.setRowsMethod:
            _setRows(MeetingReminderRow.listFromJson(call.arguments));
          case MeetingReminderChannel.closeMethod:
            _close();
        }
        return null;
      });
    } catch (e) {
      debugPrint('[MeetingReminders] window handler failed: $e');
    }
    final rows = await MeetingReminderChannel.snapshot();
    if (rows != null) _setRows(rows);
  }

  void _setRows(List<MeetingReminderRow> rows) {
    if (!mounted || _closing) return;
    if (rows.isEmpty) {
      _close();
      return;
    }
    setState(() => _rows = rows);
  }

  /// Sizes the window to what the content actually drew.
  ///
  /// The content is laid out at its natural height inside a scroll view, so
  /// its box is the height it wants however small the window is. What the
  /// frame adds on top — the title bar, whose height differs by platform — is
  /// the frame's height less the view's, so neither is guessed. Keeps the top
  /// edge where it is. Runs after every build and does nothing once it fits,
  /// so a new row, a dismissal and the theme's font loading all refit.
  void _fitToContent() {
    if (_fitScheduled) return;
    _fitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _fitScheduled = false;
      if (!mounted || _closing) return;
      final box = _contentKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final viewHeight = MediaQuery.sizeOf(context).height;
      final content = box.size.height
          .clamp(0.0, MeetingRemindersWindowApp.maxContentHeight);
      try {
        final bounds = await windowManager.getBounds();
        final target = content + (bounds.height - viewHeight);
        if ((target - bounds.height).abs() < 1) return;
        await windowManager.setBounds(
          Rect.fromLTWH(bounds.left, bounds.top, bounds.width, target),
        );
      } catch (e) {
        debugPrint('[MeetingReminders] could not fit the window: $e');
      }
    });
  }

  void _dismiss(MeetingReminderRow row) {
    unawaited(MeetingReminderChannel.silence(row.meetingKey));
    _setRows([for (final r in _rows) if (r.id != row.id) r]);
  }

  void _dismissAll() {
    for (final r in _rows) {
      unawaited(MeetingReminderChannel.dismiss(r.id));
    }
    _close();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    unawaited(windowManager.close().catchError((_) {}));
  }

  @override
  Widget build(BuildContext context) {
    _fitToContent();
    return Scaffold(
      backgroundColor: context.colors.surfacePanel,
      body: SingleChildScrollView(
        child: KeyedSubtree(
          key: _contentKey,
          child: MeetingReminderList(
            rows: _rows,
            onDismiss: _dismiss,
            onDismissAll: _dismissAll,
          ),
        ),
      ),
    );
  }
}
