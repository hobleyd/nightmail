import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/tasks/tasks_bloc.dart';
import '../blocs/tasks/tasks_event.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';
import 'tasks_page.dart';

class TasksWindowApp extends StatelessWidget {
  const TasksWindowApp({super.key});

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
    return MultiBlocProvider(
      providers: [
        BlocProvider<ThemeCubit>(create: (_) => sl<ThemeCubit>()..load()),
        BlocProvider.value(value: sl<AccountCubit>()..initialize()),
        BlocProvider(
          create: (_) => sl<TasksBloc>()..add(const TasksLoadRequested()),
        ),
      ],
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          return MaterialApp(
            title: 'Tasks',
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: switch (themeState.mode) {
              AppThemeMode.light => ThemeMode.light,
              AppThemeMode.dark => ThemeMode.dark,
              AppThemeMode.system => ThemeMode.system,
            },
            home: const _TasksWindowPage(),
          );
        },
      ),
    );
  }
}

class _TasksWindowPage extends StatelessWidget {
  const _TasksWindowPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TasksDayPanel(onClose: () {}),
    );
  }
}
