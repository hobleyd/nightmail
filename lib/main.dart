import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import 'domain/usecases/send_email.dart';
import 'injection_container.dart';
import 'presentation/blocs/account/account_cubit.dart';
import 'presentation/blocs/theme/theme_cubit.dart';
import 'presentation/blocs/theme/theme_state.dart';
import 'presentation/pages/account_selection_page.dart';
import 'presentation/pages/calendar_window.dart';
import 'presentation/pages/compose_window.dart';
import 'presentation/pages/tasks_window.dart';
import 'presentation/pages/home_page.dart';

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  if (args.firstOrNull == 'multi_window') {
    final windowId = args[1];
    final arguments = args[2].isEmpty
        ? <String, dynamic>{}
        : jsonDecode(args[2]) as Map<String, dynamic>;

    await configureDependencies();

    if (arguments['type'] == 'calendar') {
      windowManager.waitUntilReadyToShow(
        const WindowOptions(size: Size(900, 640), center: true, title: 'Calendar'),
        () async => windowManager.show(),
      );
      runApp(const CalendarWindowApp());
      return;
    }

    if (arguments['type'] == 'tasks') {
      windowManager.waitUntilReadyToShow(
        const WindowOptions(size: Size(640, 520), center: true, title: 'Tasks'),
        () async => windowManager.show(),
      );
      runApp(const TasksWindowApp());
      return;
    }

    final mode = ComposeMode.values.byName(
      arguments['mode'] as String? ?? 'newEmail',
    );
    final originalSubject =
        ((arguments['originalEmail'] as Map<String, dynamic>?)?['subject']
                as String?) ??
            '';
    final cleanSubject = originalSubject
        .replaceFirst(RegExp(r'^(?:re:\s*)+', caseSensitive: false), '')
        .trim();
    final title = switch (mode) {
      ComposeMode.newEmail => 'New Email',
      ComposeMode.reply || ComposeMode.replyAll =>
        cleanSubject.isNotEmpty ? 'Re: $cleanSubject' : 'Reply',
      ComposeMode.forward =>
        originalSubject.isNotEmpty ? 'Fwd: $originalSubject' : 'Forward',
    };

    windowManager.waitUntilReadyToShow(
      WindowOptions(size: const Size(640, 520), center: true, title: title),
      () async => windowManager.show(),
    );

    runApp(ComposeWindowApp(windowId: windowId, arguments: arguments));
    return;
  }

  await configureDependencies();
  runApp(const NightMailApp());
}

class NightMailApp extends StatefulWidget {
  const NightMailApp({super.key});

  @override
  State<NightMailApp> createState() => _NightMailAppState();
}

class _NightMailAppState extends State<NightMailApp> with WindowListener {
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
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    // Quit the whole app when the main window is closed, even if
    // compose windows are still open.
    windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ThemeCubit>(
      create: (_) => sl<ThemeCubit>()..load(),
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          return BlocProvider<AccountCubit>(
            create: (_) => sl<AccountCubit>()..initialize(),
            child: MaterialApp(
              title: 'NightMail',
              debugShowCheckedModeBanner: false,
              theme: _lightTheme,
              darkTheme: _darkTheme,
              themeMode: switch (themeState.mode) {
                AppThemeMode.light => ThemeMode.light,
                AppThemeMode.dark => ThemeMode.dark,
                AppThemeMode.system => ThemeMode.system,
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
