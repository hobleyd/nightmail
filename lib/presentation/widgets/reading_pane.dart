import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

import '../../domain/entities/email.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_state.dart';
import 'email_date_formatter.dart';

class ReadingPane extends StatelessWidget {
  const ReadingPane({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF0D0F17),
      child: BlocBuilder<EmailDetailBloc, EmailDetailState>(
        builder: (context, state) {
          return switch (state) {
            EmailDetailInitial() => const _EmptyState(),
            EmailDetailLoading() => const Center(
                child: CircularProgressIndicator(
                    color: Color(0xFF7C83FD), strokeWidth: 2),
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
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mark_email_read_outlined,
              size: 48, color: Color(0xFF1E2130)),
          SizedBox(height: 16),
          Text(
            'Select an email to read',
            style: TextStyle(color: Color(0xFF374151), fontSize: 14),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Color(0xFF6B7280), size: 36),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EmailHeader(email: email),
        const Divider(height: 1, color: Color(0xFF1A1D27)),
        Expanded(
          child: _EmailBody(email: email),
        ),
      ],
    );
  }
}

class _EmailHeader extends StatelessWidget {
  const _EmailHeader({required this.email});
  final Email email;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            email.subject,
            style: const TextStyle(
              color: Colors.white,
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: const Color(0xFF4B5563)),
        const SizedBox(width: 6),
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF4B5563),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Color(0xFF9CA3AF),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
      child: email.bodyType == EmailBodyType.html
          ? HtmlWidget(
              email.body,
              textStyle: const TextStyle(
                color: Color(0xFFD1D5DB),
                fontSize: 14,
                height: 1.6,
              ),
              customStylesBuilder: (element) {
                // Force dark-friendly text color on elements that declare
                // explicit black/white colors from the email's own stylesheet.
                if (['p', 'div', 'span', 'td', 'li']
                    .contains(element.localName)) {
                  return {'color': '#D1D5DB'};
                }
                return null;
              },
            )
          : SelectableText(
              email.body,
              style: const TextStyle(
                color: Color(0xFFD1D5DB),
                fontSize: 14,
                height: 1.6,
              ),
            ),
    );
  }
}
