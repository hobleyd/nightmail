import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/calendar/calendar_bloc.dart';
import '../blocs/calendar/calendar_event.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';
import 'calendar_page.dart';

class CalendarWindowApp extends StatelessWidget {
  const CalendarWindowApp({super.key});

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
      ],
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          return MaterialApp(
            title: 'Calendar',
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: switch (themeState.mode) {
              AppThemeMode.light => ThemeMode.light,
              AppThemeMode.dark => ThemeMode.dark,
              AppThemeMode.system => ThemeMode.system,
            },
            home: const _CalendarWindowPage(),
          );
        },
      ),
    );
  }
}

DateTime _mondayOfWeek(DateTime date) {
  return date.subtract(Duration(days: date.weekday - 1));
}

class _CalendarWindowPage extends StatefulWidget {
  const _CalendarWindowPage();

  @override
  State<_CalendarWindowPage> createState() => _CalendarWindowPageState();
}

class _CalendarWindowPageState extends State<_CalendarWindowPage> {
  static const _calendarRefreshChannel =
      MethodChannel('au.com.sharpblue.nightmail/calendar_refresh');

  @override
  void initState() {
    super.initState();
    _calendarRefreshChannel.setMethodCallHandler((call) async {
      if (call.method == 'eventSaved' && mounted) {
        final bloc = context.read<CalendarBloc>();
        bloc.add(CalendarWeekNavigated(weekStart: bloc.state.weekStart));
      }
    });
  }

  @override
  void dispose() {
    _calendarRefreshChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) {
        final monday = _mondayOfWeek(DateTime.now());
        return sl<CalendarBloc>()
          ..add(CalendarWeekLoadRequested(weekStart: monday));
      },
      child: const Scaffold(
        body: CalendarPage(),
      ),
    );
  }
}
