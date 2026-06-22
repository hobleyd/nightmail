import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_address.dart';
import '../../injection_container.dart';
import '../blocs/theme/theme_cubit.dart';
import '../blocs/theme/theme_state.dart';
import '../widgets/html_body_view.dart';

class EmailViewWindowApp extends StatelessWidget {
  const EmailViewWindowApp({
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
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C83FD)),
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
            home: _EmailViewPage(arguments: arguments),
          );
        },
      ),
    );
  }
}

class _EmailViewPage extends StatelessWidget {
  const _EmailViewPage({required this.arguments});

  final Map<String, dynamic> arguments;

  Email _buildEmail() {
    final map = arguments['email'] as Map<String, dynamic>? ?? {};
    EmailAddress parseAddress(Map<String, dynamic> m) =>
        EmailAddress(address: m['address'] as String, name: m['name'] as String?);
    final bodyTypeStr = map['bodyType'] as String? ?? 'text';
    final receivedStr = map['receivedDateTime'] as String?;
    return Email(
      id: map['id'] as String? ?? '',
      subject: map['subject'] as String? ?? '',
      from: parseAddress(
          (map['from'] as Map<String, dynamic>?) ?? {'address': '', 'name': null}),
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
      receivedDateTime: receivedStr != null
          ? DateTime.tryParse(receivedStr) ?? DateTime.now()
          : DateTime.now(),
      importance: EmailImportance.normal,
    );
  }

  static String _senderDomain(String address) {
    final at = address.lastIndexOf('@');
    if (at == -1 || at == address.length - 1) return address.toLowerCase();
    return address.substring(at + 1).toLowerCase();
  }

  static String _formatAddress(EmailAddress addr) {
    final name = addr.name;
    if (name != null && name.isNotEmpty) return '$name <${addr.address}>';
    return addr.address;
  }

  static String _formatDate(DateTime dt) {
    final d = dt.toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final email = _buildEmail();

    return Scaffold(
      backgroundColor: c.surfacePanel,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(
            title: email.subject.isNotEmpty ? email.subject : '(No Subject)',
            onClose: () => windowManager.close(),
          ),
          Divider(height: 1, color: c.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HeaderRow(
                  label: 'From',
                  value: _formatAddress(email.from),
                  colors: c,
                ),
                const SizedBox(height: 4),
                _HeaderRow(
                  label: 'To',
                  value: email.toRecipients.map(_formatAddress).join('; '),
                  colors: c,
                ),
                if (email.ccRecipients.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _HeaderRow(
                    label: 'Cc',
                    value: email.ccRecipients.map(_formatAddress).join('; '),
                    colors: c,
                  ),
                ],
                const SizedBox(height: 4),
                _HeaderRow(
                  label: 'Date',
                  value: _formatDate(email.receivedDateTime),
                  colors: c,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          Expanded(
            child: email.bodyType == EmailBodyType.html
                ? HtmlBodyView(
                    html: email.body,
                    inlineAttachments: const [],
                    senderDomain: _senderDomain(email.from.address),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    child: SelectableText(
                      email.body,
                      style: TextStyle(
                        color: c.textBody,
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClose,
            color: c.textMuted,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.label,
    required this.value,
    required this.colors,
  });

  final String label;
  final String value;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: colors.textMuted,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(fontSize: 12, color: colors.textPrimary),
          ),
        ),
      ],
    );
  }
}
