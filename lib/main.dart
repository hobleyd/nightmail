import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import 'core/settings/window_bounds_service.dart';
import 'domain/usecases/send_email.dart';
import 'infrastructure/accounts/account_manager.dart';
import 'infrastructure/background/background_mail_service.dart';
import 'infrastructure/notifications/notification_service.dart';
import 'injection_container.dart';
import 'presentation/blocs/account/account_cubit.dart';
import 'presentation/blocs/theme/theme_cubit.dart';
import 'presentation/blocs/theme/theme_state.dart';
import 'presentation/pages/account_selection_page.dart';
import 'presentation/pages/calendar_window.dart';
import 'presentation/pages/compose_window.dart';
import 'presentation/pages/email_view_window.dart';
import 'presentation/pages/event_edit_window.dart';
import 'presentation/pages/reminder_popup_window.dart';
import 'presentation/pages/tasks_window.dart';
import 'presentation/pages/home_page.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await windowManager.ensureInitialized();
  } catch (_) {
    // window_manager is not available in sub-window processes — safe to ignore.
  }

  if (args.firstOrNull == 'multi_window') {
    final windowId = args[1];
    final arguments = args[2].isEmpty
        ? <String, dynamic>{}
        : jsonDecode(args[2]) as Map<String, dynamic>;

    await configureDependencies();
    await sl<AccountManager>().initialize();

    Future<void> showSubWindow(WindowOptions options) async {
      try {
        await windowManager.waitUntilReadyToShow(options);
        await (await WindowController.fromCurrentEngine()).show();
      } catch (_) {
        // Fallback: window_manager unavailable in this sub-window context.
        await (await WindowController.fromCurrentEngine()).show();
      }
    }

    if (arguments['type'] == 'calendar') {
      await showSubWindow(
        const WindowOptions(size: Size(900, 640), center: true, title: 'Calendar'),
      );
      runApp(const CalendarWindowApp());
      return;
    }

    if (arguments['type'] == 'tasks') {
      await showSubWindow(
        const WindowOptions(size: Size(640, 520), center: true, title: 'Tasks'),
      );
      runApp(const TasksWindowApp());
      return;
    }

    if (arguments['type'] == 'eventEdit') {
      final rawEvent = arguments['event'] as Map<String, dynamic>?;
      final subject = rawEvent?['subject'] as String?;
      final title = rawEvent != null
          ? (subject?.isNotEmpty == true ? subject! : 'Edit Event')
          : 'New Event';
      await showSubWindow(
        WindowOptions(size: const Size(600, 580), center: true, title: title),
      );
      runApp(EventEditWindowApp(windowId: windowId, arguments: arguments));
      return;
    }

    if (arguments['type'] == 'eventReminder') {
      final title = arguments['eventTitle'] as String? ?? 'Reminder';
      await showSubWindow(
        WindowOptions(size: const Size(300, 160), center: true, title: title),
      );
      runApp(ReminderPopupWindowApp(arguments: arguments));
      return;
    }

    if (arguments['type'] == 'emailView') {
      final emailMap = arguments['email'] as Map<String, dynamic>? ?? {};
      final subject = emailMap['subject'] as String? ?? '';
      final title = subject.isNotEmpty ? subject : '(No Subject)';
      await showSubWindow(
        WindowOptions(size: const Size(720, 580), center: true, title: title),
      );
      runApp(EmailViewWindowApp(windowId: windowId, arguments: arguments));
      return;
    }

    final mode = ComposeMode.values.byName(
      arguments['mode'] as String? ?? 'newEmail',
    );

    final draftEmailRaw = arguments['draftEmail'] as Map<String, dynamic>?;
    final originalSubject =
        ((arguments['originalEmail'] as Map<String, dynamic>?)?['subject']
                as String?) ??
            '';
    final cleanSubject = originalSubject
        .replaceFirst(RegExp(r'^(?:re:\s*)+', caseSensitive: false), '')
        .trim();
    final title = draftEmailRaw != null
        ? () {
            final s = draftEmailRaw['subject'] as String? ?? '';
            return s.isNotEmpty ? s : 'Draft';
          }()
        : switch (mode) {
            ComposeMode.newEmail => 'New Email',
            ComposeMode.reply || ComposeMode.replyAll =>
              cleanSubject.isNotEmpty ? 'Re: $cleanSubject' : 'Reply',
            ComposeMode.forward =>
              originalSubject.isNotEmpty ? 'Fwd: $originalSubject' : 'Forward',
          };

    await showSubWindow(
      WindowOptions(size: const Size(640, 520), center: true, title: title),
    );

    runApp(ComposeWindowApp(windowId: windowId, arguments: arguments));
    return;
  }

await configureDependencies();
  await BackgroundMailService.initialize();
  await BackgroundMailService.schedulePeriodicCheck();
  // Eagerly initialize NotificationService (installs method-call handlers and
  // local-notifications plugin), then request permission without blocking startup.
  unawaited(sl<NotificationService>().requestPermission());

  if (!kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
    try {
      final restored = await WindowBoundsService().loadValidatedBounds();
      if (restored != null) {
        if (restored.fullScreen) {
          await windowManager.setFullScreen(true);
        } else if (restored.maximized) {
          await windowManager.maximize();
        } else if (restored.bounds != null) {
          await windowManager.setBounds(restored.bounds!);
        }
      }
    } catch (_) {}
  }

  runApp(const NightMailApp());
}

class NightMailApp extends StatefulWidget {
  const NightMailApp({super.key});

  @override
  State<NightMailApp> createState() => _NightMailAppState();
}

class _NightMailAppState extends State<NightMailApp> with WindowListener {
  final _windowBoundsService = WindowBoundsService();
  Timer? _boundsDebounce;

  static ThemeData _buildTheme({String? fontFamily, bool dark = false}) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF7C83FD),
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      fontFamily: fontFamily,
      useMaterial3: true,
    );
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
  }

  @override
  void dispose() {
    _boundsDebounce?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  void _scheduleBoundsSave() {
    _boundsDebounce?.cancel();
    _boundsDebounce = Timer(
      const Duration(milliseconds: 500),
      () async {
        try {
          // Special states are handled by their own event overrides below.
          if (await windowManager.isMaximized()) return;
          if (await windowManager.isFullScreen()) return;
          final bounds = await windowManager.getBounds();
          await _windowBoundsService.saveBounds(bounds);
        } catch (_) {}
      },
    );
  }

  Future<void> _saveCurrentState() async {
    try {
      final isFullScreen = await windowManager.isFullScreen();
      final isMaximized = await windowManager.isMaximized();
      final bounds = await windowManager.getBounds();
      await _windowBoundsService.saveBounds(
        bounds,
        fullScreen: isFullScreen,
        maximized: isMaximized,
      );
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    // Quit the whole app when the main window is closed, even if
    // compose windows are still open.
    _boundsDebounce?.cancel();
    await _saveCurrentState();
    windowManager.destroy();
  }

  // Save immediately when entering a special state so a subsequent quit
  // doesn't have to re-query the (now-changed) window state.
  @override
  void onWindowMaximize() => _saveCurrentState();

  @override
  void onWindowEnterFullScreen() => _saveCurrentState();

  // macOS/Windows: fires once when resize/move finishes.
  @override
  void onWindowResized() => _scheduleBoundsSave();

  @override
  void onWindowMoved() => _scheduleBoundsSave();

  // Linux: fires continuously during resize/move — debounce handles it.
  @override
  void onWindowResize() => _scheduleBoundsSave();

  @override
  void onWindowMove() => _scheduleBoundsSave();

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ThemeCubit>(
      create: (_) => sl<ThemeCubit>()..load(),
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          final lightTheme = _buildTheme(fontFamily: themeState.fontFamily);
          final darkTheme = _buildTheme(fontFamily: themeState.fontFamily, dark: true);
          return BlocProvider<AccountCubit>(
            create: (_) => sl<AccountCubit>()..initialize(),
            child: MaterialApp(
              title: 'NightMail',
              debugShowCheckedModeBanner: false,
              theme: lightTheme,
              darkTheme: darkTheme,
              themeMode: switch (themeState.mode) {
                AppThemeMode.light => ThemeMode.light,
                AppThemeMode.dark => ThemeMode.dark,
                AppThemeMode.system => ThemeMode.system,
              },
              builder: (context, child) {
                final scale = themeState.fontScale;
                if (scale == 1.0) return child!;
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: child!,
                );
              },
              home: const _AccountGate(),
            ),
          );
        },
      ),
    );
  }
}

class _AccountGate extends StatelessWidget {
  const _AccountGate();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<AccountCubit, AccountState>(
      builder: (context, state) {
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: switch (state) {
            AccountLoading() => const _SplashScreen(),
            AccountNoAccounts() => const AccountSelectionPage(),
            AccountsLoaded() => const HomePage(),
            AccountError(:final message) =>
              AccountSelectionPage(errorMessage: message),
          },
        );
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: const Center(
        child: CircularProgressIndicator(
          color: Color(0xFF7C83FD),
          strokeWidth: 2,
        ),
      ),
    );
  }
}
