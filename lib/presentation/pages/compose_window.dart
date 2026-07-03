import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/platform/window_utils.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_address.dart';
import '../../domain/entities/email_attachment.dart';
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

  /// Opens a compose screen: a new push route on mobile, a sub-window on desktop.
  static Future<void> open(
    BuildContext context, {
    required ComposeMode mode,
    Email? originalEmail,
    Email? draftEmail,
    String? existingDraftId,
    VoidCallback? onSent,
  }) async {
    final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    if (isMobile) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _MobileComposePage(
            mode: mode,
            originalEmail: originalEmail,
            draftEmail: draftEmail,
            existingDraftId: existingDraftId,
            onSent: onSent,
          ),
          fullscreenDialog: true,
        ),
      );
      return;
    }

    Map<String, dynamic> args = {'mode': mode.name};
    if (existingDraftId != null) args['existingDraftId'] = existingDraftId;
    if (originalEmail != null) {
      args['originalEmail'] = {
        'id': originalEmail.id,
        'subject': originalEmail.subject,
        'from': {
          'address': originalEmail.from.address,
          'name': originalEmail.from.name,
        },
        'toRecipients': originalEmail.toRecipients
            .map((r) => {'address': r.address, 'name': r.name})
            .toList(),
        'ccRecipients': originalEmail.ccRecipients
            .map((r) => {'address': r.address, 'name': r.name})
            .toList(),
        'body': originalEmail.body,
        'bodyType': originalEmail.bodyType.name,
        'receivedDateTime': originalEmail.receivedDateTime.toIso8601String(),
        'attachments': originalEmail.attachments
            .map((a) => {
                  'id': a.id,
                  'name': a.name,
                  'contentType': a.contentType,
                  'size': a.size,
                })
            .toList(),
      };
    }
    if (draftEmail != null) {
      args['draftEmail'] = {
        'subject': draftEmail.subject,
        'toRecipients': draftEmail.toRecipients
            .map((r) => {'address': r.address, 'name': r.name})
            .toList(),
        'ccRecipients': draftEmail.ccRecipients
            .map((r) => {'address': r.address, 'name': r.name})
            .toList(),
        'body': draftEmail.body,
        'bodyType': draftEmail.bodyType.name,
      };
    }
    await createSubWindow(
      WindowConfiguration(arguments: jsonEncode(args)),
    );
  }

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

class _ComposeWindowPage extends StatefulWidget {
  const _ComposeWindowPage({
    required this.windowId,
    required this.mode,
    required this.arguments,
  });

  final String windowId;
  final ComposeMode mode;
  final Map<String, dynamic> arguments;

  @override
  State<_ComposeWindowPage> createState() => _ComposeWindowPageState();
}

class _ComposeWindowPageState extends State<_ComposeWindowPage> {
  EmailBodyType _defaultComposeFormat = AppSettings.defaultComposeFormat;

  @override
  void initState() {
    super.initState();
    sl<AppSettings>().loadDefaultComposeFormat().then((format) {
      if (mounted) setState(() => _defaultComposeFormat = format);
    });
  }

  void _close() => windowManager.close();

  Email? _originalEmail() {
    final raw = widget.arguments['originalEmail'];
    if (raw == null) return null;
    final map = raw as Map<String, dynamic>;
    EmailAddress parseAddress(Map<String, dynamic> m) =>
        EmailAddress(address: m['address'] as String, name: m['name'] as String?);

    final bodyTypeStr = map['bodyType'] as String? ?? 'text';
    final receivedStr = map['receivedDateTime'] as String?;
    final attachmentsJson = map['attachments'] as List<dynamic>? ?? [];

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
      body: map['body'] as String? ?? '',
      bodyType: bodyTypeStr == 'html' ? EmailBodyType.html : EmailBodyType.text,
      isRead: true,
      receivedDateTime: receivedStr != null
          ? DateTime.tryParse(receivedStr) ?? DateTime.now()
          : DateTime.now(),
      importance: EmailImportance.normal,
      attachments: attachmentsJson.map((a) {
        final aMap = a as Map<String, dynamic>;
        return EmailAttachment(
          id: aMap['id'] as String,
          name: aMap['name'] as String,
          contentType: aMap['contentType'] as String,
          size: (aMap['size'] as num).toInt(),
        );
      }).toList(),
    );
  }

  Email? _draftEmail() {
    final raw = widget.arguments['draftEmail'];
    if (raw == null) return null;
    final map = raw as Map<String, dynamic>;
    EmailAddress parseAddress(Map<String, dynamic> m) =>
        EmailAddress(address: m['address'] as String, name: m['name'] as String?);
    final bodyTypeStr = map['bodyType'] as String? ?? 'text';
    return Email(
      id: '',
      subject: map['subject'] as String? ?? '',
      from: const EmailAddress(address: '', name: null),
      toRecipients: (map['toRecipients'] as List<dynamic>? ?? [])
          .map((r) => parseAddress(r as Map<String, dynamic>))
          .toList(),
      ccRecipients: (map['ccRecipients'] as List<dynamic>? ?? [])
          .map((r) => parseAddress(r as Map<String, dynamic>))
          .toList(),
      bodyPreview: '',
      body: map['body'] as String? ?? '',
      bodyType: bodyTypeStr == 'html' ? EmailBodyType.html : EmailBodyType.text,
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
    final accountDomain = _domainOf(account?.emailAddress);
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
            mode: widget.mode,
            originalEmail: _originalEmail(),
            draftEmail: _draftEmail(),
            onClose: _close,
            fromAddress: fromAddress,
            accountId: accountId,
            accountDomain: accountDomain,
            scrollable: true,
            existingDraftId: widget.arguments['existingDraftId'] as String?,
            onTitleChanged: (title) => windowManager.setTitle(title),
            defaultComposeFormat: _defaultComposeFormat,
          ),
        ),
      ),
    );
  }

  static String? _domainOf(String? email) {
    if (email == null) return null;
    final at = email.lastIndexOf('@');
    if (at < 0 || at == email.length - 1) return null;
    return email.substring(at + 1).toLowerCase();
  }
}

// ---------------------------------------------------------------------------
// Mobile full-screen compose route
// ---------------------------------------------------------------------------

class _MobileComposePage extends StatefulWidget {
  const _MobileComposePage({
    required this.mode,
    this.originalEmail,
    this.draftEmail,
    this.existingDraftId,
    this.onSent,
  });

  final ComposeMode mode;
  final Email? originalEmail;
  final Email? draftEmail;
  final String? existingDraftId;
  final VoidCallback? onSent;

  @override
  State<_MobileComposePage> createState() => _MobileComposePageState();
}

class _MobileComposePageState extends State<_MobileComposePage> {
  EmailBodyType _defaultComposeFormat = AppSettings.defaultComposeFormat;

  @override
  void initState() {
    super.initState();
    sl<AppSettings>().loadDefaultComposeFormat().then((format) {
      if (mounted) setState(() => _defaultComposeFormat = format);
    });
  }

  static String? _domainOf(String? email) {
    if (email == null) return null;
    final at = email.lastIndexOf('@');
    if (at < 0 || at == email.length - 1) return null;
    return email.substring(at + 1).toLowerCase();
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

    return BlocProvider(
      create: (_) => ComposeBloc(sendEmail: sl<SendEmail>()),
      child: Scaffold(
        backgroundColor: c.surfacePanel,
        body: SafeArea(
          child: BlocListener<ComposeBloc, ComposeState>(
            listener: (context, state) {
              if (state is ComposeSent || state is ComposeError) {
                if (state is ComposeError) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(state.message),
                      backgroundColor: Colors.red.shade700,
                    ),
                  );
                }
                if (state is ComposeSent) {
                  Navigator.of(context).pop();
                  widget.onSent?.call();
                }
              }
            },
            child: ComposeForm(
              mode: widget.mode,
              originalEmail: widget.originalEmail,
              draftEmail: widget.draftEmail,
              onClose: () => Navigator.of(context).pop(),
              fromAddress: fromAddress,
              accountId: account?.id,
              accountDomain: _domainOf(account?.emailAddress),
              scrollable: true,
              existingDraftId: widget.existingDraftId,
              defaultComposeFormat: _defaultComposeFormat,
            ),
          ),
        ),
      ),
    );
  }
}
