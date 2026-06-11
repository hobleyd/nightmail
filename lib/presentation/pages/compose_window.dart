import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_address.dart';
import '../../domain/usecases/send_email.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../injection_container.dart';
import '../blocs/compose/compose_bloc.dart';
import '../blocs/compose/compose_state.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';
import '../widgets/compose_dialog.dart';

class ComposeWindowApp extends StatelessWidget {
  const ComposeWindowApp({
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
            home: _ComposeWindowPage(
              windowId: windowId,
              mode: ComposeMode.values.byName(
                arguments['mode'] as String? ?? 'newEmail',
              ),
              arguments: arguments,
            ),
          );
        },
      ),
    );
  }
}

class _ComposeWindowPage extends StatelessWidget {
  const _ComposeWindowPage({
    required this.windowId,
    required this.mode,
    required this.arguments,
  });

  final String windowId;
  final ComposeMode mode;
  final Map<String, dynamic> arguments;

  void _close() => windowManager.close();

  Email? _originalEmail() {
    final raw = arguments['originalEmail'];
    if (raw == null) return null;
    final map = raw as Map<String, dynamic>;
    EmailAddress parseAddress(Map<String, dynamic> m) =>
        EmailAddress(address: m['address'] as String, name: m['name'] as String?);
    return Email(
      id: map['id'] as String,
      subject: map['subject'] as String,
      from: parseAddress(map['from'] as Map<String, dynamic>),
      toRecipients: (map['toRecipients'] as List<dynamic>)
          .map((r) => parseAddress(r as Map<String, dynamic>))
          .toList(),
      ccRecipients: (map['ccRecipients'] as List<dynamic>)
          .map((r) => parseAddress(r as Map<String, dynamic>))
          .toList(),
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime.now(),
      importance: EmailImportance.normal,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final account = sl<AccountManager>().activeAccount;
    final fromAddress = account == null
        ? ''
        : account.displayName.isNotEmpty
            ? '${account.displayName} <${account.emailAddress}>'
            : account.emailAddress;
    final accountId = account?.id;
    return BlocProvider(
      create: (_) => ComposeBloc(sendEmail: sl<SendEmail>()),
      child: Scaffold(
        backgroundColor: c.surfacePanel,
        body: BlocListener<ComposeBloc, ComposeState>(
          listener: (context, state) {
            if (state is ComposeSent) {
              _close();
            } else if (state is ComposeError) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(state.message),
                  backgroundColor: Colors.red.shade700,
                ),
              );
            }
          },
          child: ComposeForm(
            mode: mode,
            originalEmail: _originalEmail(),
            onClose: _close,
            fromAddress: fromAddress,
            accountId: accountId,
            scrollable: true,
            onTitleChanged: (title) => windowManager.setTitle(title),
          ),
        ),
      ),
    );
  }
}
