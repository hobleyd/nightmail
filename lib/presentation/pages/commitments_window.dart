import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/platform/window_utils.dart';
import '../../core/settings/window_bounds_service.dart';
import '../../domain/entities/commitment.dart';
import '../../domain/usecases/get_email.dart';
import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/commitments/commitments_cubit.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';
import 'commitments_page.dart';

/// The Commitments pane in its own window, opened by double-clicking the
/// Commitments button at the foot of the folder panel.
///
/// `main()` sizes it to the screen it was opened from (or to where the user
/// last left one — see `commitmentsWindowBounds`), and at that width
/// `CommitmentsDayPanel` lays its sections out as a four-column board. This
/// engine has no reading pane, so a row opens its message in an email-view
/// window instead (`onOpenEmail`), the way a double-clicked list row does in
/// the main window.
class CommitmentsWindowApp extends StatelessWidget {
  const CommitmentsWindowApp({super.key});

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
        BlocProvider(create: (_) => sl<CommitmentsCubit>()),
      ],
      child: BlocBuilder<ThemeCubit, ThemeState>(
        builder: (context, themeState) {
          return MaterialApp(
            title: 'Commitments',
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: switch (themeState.mode) {
              AppThemeMode.light => ThemeMode.light,
              AppThemeMode.dark => ThemeMode.dark,
              AppThemeMode.system => ThemeMode.system,
            },
            home: const _CommitmentsWindowPage(),
          );
        },
      ),
    );
  }
}

class _CommitmentsWindowPage extends StatefulWidget {
  const _CommitmentsWindowPage();

  @override
  State<_CommitmentsWindowPage> createState() => _CommitmentsWindowPageState();
}

class _CommitmentsWindowPageState extends State<_CommitmentsWindowPage>
    with WindowListener {
  Timer? _boundsDebounce;

  @override
  void initState() {
    super.initState();
    try {
      windowManager.addListener(this);
    } catch (_) {}
  }

  @override
  void dispose() {
    _boundsDebounce?.cancel();
    try {
      windowManager.removeListener(this);
    } catch (_) {}
    super.dispose();
  }

  // ── Window geometry ──────────────────────────────────────────────────────
  //
  // The same debounce-and-save compose uses, against this kind's own file
  // (`commitmentsWindowBounds`), so the next Commitments window opens where
  // this one was left. Linux fires resize/move continuously, hence the
  // debounce.

  void _scheduleBoundsSave() {
    _boundsDebounce?.cancel();
    _boundsDebounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        if (await windowManager.isMaximized()) return;
        if (await windowManager.isFullScreen()) return;
        await commitmentsWindowBounds.saveBounds(await windowManager.getBounds());
      } catch (_) {}
    });
  }

  Future<void> _saveCurrentState() async {
    try {
      final fullScreen = await windowManager.isFullScreen();
      final maximized = await windowManager.isMaximized();
      await commitmentsWindowBounds.saveBounds(
        await windowManager.getBounds(),
        fullScreen: fullScreen,
        maximized: maximized,
      );
    } catch (_) {}
  }

  @override
  void onWindowResized() => _scheduleBoundsSave();

  @override
  void onWindowMoved() => _scheduleBoundsSave();

  @override
  void onWindowResize() => _scheduleBoundsSave();

  @override
  void onWindowMove() => _scheduleBoundsSave();

  @override
  void onWindowMaximize() => _saveCurrentState();

  @override
  void onWindowEnterFullScreen() => _saveCurrentState();

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _close() async {
    try {
      await windowManager.close();
    } catch (_) {}
  }

  /// Opens the commitment's message in an email-view window: this engine has
  /// no reading pane. The full body is fetched first — the ledger only holds
  /// the message id — and the window is given the same shape of email map
  /// the main window's double-click hands it.
  Future<void> _openEmailInWindow(Commitment commitment) async {
    final result = await sl<GetEmail>()(GetEmailParams(id: commitment.emailId));
    if (!mounted) return;
    await result.fold(
      (failure) async {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the message: ${failure.message}')),
        );
      },
      (full) => createSubWindow(
        WindowConfiguration(
          arguments: jsonEncode({
            'type': 'emailView',
            'email': {
              'id': full.id,
              'subject': full.subject,
              'from': {'address': full.from.address, 'name': full.from.name},
              'toRecipients': full.toRecipients
                  .map((r) => {'address': r.address, 'name': r.name})
                  .toList(),
              'ccRecipients': full.ccRecipients
                  .map((r) => {'address': r.address, 'name': r.name})
                  .toList(),
              'body': full.body,
              'bodyType': full.bodyType.name,
              'receivedDateTime': full.receivedDateTime.toIso8601String(),
            },
          }),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CommitmentsDayPanel(
        onClose: _close,
        onOpenEmail: _openEmailInWindow,
      ),
    );
  }
}
