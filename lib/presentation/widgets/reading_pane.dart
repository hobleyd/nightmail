import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/usecases/delete_email.dart';
import '../../domain/usecases/send_email.dart';
import '../../injection_container.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_detail/email_detail_state.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import 'compose_dialog.dart';
import 'email_date_formatter.dart';

class ReadingPane extends StatelessWidget {
  const ReadingPane({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfaceReading,
      child: BlocBuilder<EmailDetailBloc, EmailDetailState>(
        builder: (context, state) {
          return switch (state) {
            EmailDetailInitial() => const _EmptyState(),
            EmailDetailLoading() => Center(
                child: CircularProgressIndicator(
                    color: AppColors.accent, strokeWidth: 2),
              ),
            EmailDetailLoaded(:final email) => _EmailView(email: email),
            EmailDetailError(:final message) => _ErrorState(message: message),
          };
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mark_email_read_outlined,
              size: 48, color: c.stateIcon),
          const SizedBox(height: 16),
          Text(
            'Select an email to read',
            style: TextStyle(color: c.stateText, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: c.textMuted, size: 36),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmailView extends StatelessWidget {
  const _EmailView({required this.email});
  final Email email;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReadingPaneToolbar(email: email),
        Divider(height: 1, color: c.border),
        _EmailHeader(email: email),
        Divider(height: 1, color: c.border),
        Expanded(
          child: _EmailBody(email: email),
        ),
      ],
    );
  }
}

class _ReadingPaneToolbar extends StatelessWidget {
  const _ReadingPaneToolbar({required this.email});
  final Email email;

  Future<void> _confirmAndDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete email', style: TextStyle(fontSize: 15)),
        content: const Text(
          'Move this email to Deleted Items?',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final result =
        await sl<DeleteEmail>()(DeleteEmailParams(id: email.id));

    if (!context.mounted) return;

    result.fold(
      (f) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(f.message)),
      ),
      (_) {
        context.read<EmailDetailBloc>().add(const EmailDetailCleared());
        context.read<EmailListBloc>().add(
              EmailListEmailDeleted(emailId: email.id),
            );
      },
    );
  }

  Future<void> _copyToClipboard(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: email.body));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Email body copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          _ToolbarButton(
            icon: Icons.reply_rounded,
            tooltip: 'Reply',
            color: c.textMuted,
            onPressed: () => ComposeDialog.show(
              context,
              mode: ComposeMode.reply,
              originalEmail: email,
            ),
          ),
          _ToolbarButton(
            icon: Icons.reply_all_rounded,
            tooltip: 'Reply All',
            color: c.textMuted,
            onPressed: () => ComposeDialog.show(
              context,
              mode: ComposeMode.replyAll,
              originalEmail: email,
            ),
          ),
          _ToolbarButton(
            icon: Icons.forward_to_inbox_rounded,
            tooltip: 'Forward',
            color: c.textMuted,
            onPressed: () => ComposeDialog.show(
              context,
              mode: ComposeMode.forward,
              originalEmail: email,
            ),
          ),
          const Spacer(),
          _ToolbarButton(
            icon: Icons.content_copy_outlined,
            tooltip: 'Debug: copy body to clipboard',
            color: c.textMuted,
            onPressed: () => _copyToClipboard(context),
          ),
          _ToolbarButton(
            icon: Icons.delete_outline_rounded,
            tooltip: 'Delete',
            color: c.textMuted,
            onPressed: () => _confirmAndDelete(context),
          ),
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16, color: color),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: onPressed,
    );
  }
}

class _EmailHeader extends StatelessWidget {
  const _EmailHeader({required this.email});
  final Email email;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            email.subject,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 16),
          _MetaRow(
            icon: Icons.person_outline_rounded,
            label: 'From',
            value: '${email.from.displayName} <${email.from.address}>',
          ),
          if (email.toRecipients.isNotEmpty) ...[
            const SizedBox(height: 6),
            _MetaRow(
              icon: Icons.mail_outline_rounded,
              label: 'To',
              value: email.toRecipients
                  .map((r) => r.displayName)
                  .join(', '),
            ),
          ],
          if (email.ccRecipients.isNotEmpty) ...[
            const SizedBox(height: 6),
            _MetaRow(
              icon: Icons.people_outline_rounded,
              label: 'Cc',
              value: email.ccRecipients
                  .map((r) => r.displayName)
                  .join(', '),
            ),
          ],
          const SizedBox(height: 6),
          _MetaRow(
            icon: Icons.schedule_rounded,
            label: 'Date',
            value: formatEmailDateLong(email.receivedDateTime),
          ),
          if (email.hasAttachments) ...[
            const SizedBox(height: 6),
            const _MetaRow(
              icon: Icons.attach_file_rounded,
              label: 'Attachments',
              value: 'This email has attachments',
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: c.textDimmed),
        const SizedBox(width: 6),
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: TextStyle(
              color: c.textDimmed,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: c.textTertiary,
              fontSize: 12,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _EmailBody extends StatelessWidget {
  const _EmailBody({required this.email});
  final Email email;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final htmlColor = c.textBodyHtml;

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: constraints.maxWidth - 56, // Account for horizontal padding
            ),
            child: email.bodyType == EmailBodyType.html
                ? HtmlWidget(
                    email.body,
                    textStyle: TextStyle(
                      color: c.textBody,
                      fontSize: 14,
                      height: 1.6,
                    ),
                    customStylesBuilder: (element) {
                      final styles = <String, String>{};

                      // Override explicit black/white colors from the email's stylesheet.
                      if (['p', 'div', 'span', 'td', 'li']
                          .contains(element.localName)) {
                        styles['color'] = htmlColor;
                      }

                      // Force tables and common containers to be responsive and fill width.
                      if (['table', 'div', 'section', 'article', 'body']
                          .contains(element.localName)) {
                        styles['max-width'] = 'none';
                        styles['min-width'] = '0';
                        if (element.localName == 'table') {
                          styles['height'] = 'auto';
                          styles['width'] = '100%';
                        }
                      }

                      return styles.isEmpty ? null : styles;
                    },
                  )
                : SelectableText(
                    email.body,
                    style: TextStyle(
                      color: c.textBody,
                      fontSize: 14,
                      height: 1.6,
                    ),
                  ),
          ),
        );
      },
    );
  }
}
