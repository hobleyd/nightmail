import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/usecases/send_email.dart';
import '../../injection_container.dart';
import '../blocs/compose/compose_bloc.dart';
import '../blocs/compose/compose_event.dart';
import '../blocs/compose/compose_state.dart';

class ComposeDialog extends StatelessWidget {
  const ComposeDialog({
    super.key,
    required this.mode,
    this.originalEmail,
  });

  final ComposeMode mode;
  final Email? originalEmail;

  static Future<void> show(
    BuildContext context, {
    required ComposeMode mode,
    Email? originalEmail,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BlocProvider(
        create: (_) => ComposeBloc(sendEmail: sl<SendEmail>()),
        child: ComposeDialog(mode: mode, originalEmail: originalEmail),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ComposeBloc, ComposeState>(
      listener: (context, state) {
        if (state is ComposeSent) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Email sent'),
              duration: Duration(seconds: 2),
            ),
          );
        } else if (state is ComposeError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      },
      child: _ComposeForm(mode: mode, originalEmail: originalEmail),
    );
  }
}

class _ComposeForm extends StatefulWidget {
  const _ComposeForm({required this.mode, this.originalEmail});

  final ComposeMode mode;
  final Email? originalEmail;

  @override
  State<_ComposeForm> createState() => _ComposeFormState();
}

class _ComposeFormState extends State<_ComposeForm> {
  late final TextEditingController _toController;
  late final TextEditingController _ccController;
  late final TextEditingController _subjectController;
  late final TextEditingController _bodyController;
  final FocusNode _bodyFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _toController = TextEditingController(text: _initialTo());
    _ccController = TextEditingController(text: _initialCc());
    _subjectController = TextEditingController(text: _initialSubject());
    _bodyController = TextEditingController();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bodyFocus.requestFocus();
    });
  }

  String _initialTo() {
    final email = widget.originalEmail;
    if (email == null) return '';
    return switch (widget.mode) {
      ComposeMode.reply => email.from.address,
      ComposeMode.replyAll => [
          email.from.address,
          ...email.toRecipients.map((r) => r.address),
        ].join(', '),
      ComposeMode.forward => '',
      ComposeMode.newEmail => '',
    };
  }

  String _initialCc() {
    final email = widget.originalEmail;
    if (email == null) return '';
    return switch (widget.mode) {
      ComposeMode.replyAll =>
        email.ccRecipients.map((r) => r.address).join(', '),
      _ => '',
    };
  }

  String _initialSubject() {
    final email = widget.originalEmail;
    if (email == null) return '';
    final subject = email.subject;
    return switch (widget.mode) {
      ComposeMode.reply ||
      ComposeMode.replyAll =>
        subject.startsWith('Re:') ? subject : 'Re: $subject',
      ComposeMode.forward => 'Fwd: $subject',
      ComposeMode.newEmail => '',
    };
  }

  @override
  void dispose() {
    _toController.dispose();
    _ccController.dispose();
    _subjectController.dispose();
    _bodyController.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  String get _title => switch (widget.mode) {
        ComposeMode.newEmail => 'New Email',
        ComposeMode.reply => 'Reply',
        ComposeMode.replyAll => 'Reply All',
        ComposeMode.forward => 'Forward',
      };

  bool get _toEditable => switch (widget.mode) {
        ComposeMode.newEmail || ComposeMode.forward => true,
        _ => false,
      };

  bool get _subjectEditable => widget.mode == ComposeMode.newEmail;

  void _submit(BuildContext context) {
    final to = _toController.text.trim();
    final cc = _ccController.text.trim();
    final subject = _subjectController.text.trim();
    final body = _bodyController.text.trim();

    if (body.isEmpty &&
        widget.mode != ComposeMode.forward) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message body cannot be empty')),
      );
      return;
    }

    if ((widget.mode == ComposeMode.newEmail ||
            widget.mode == ComposeMode.forward) &&
        to.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter at least one recipient')),
      );
      return;
    }

    final toAddresses =
        to.isEmpty ? <String>[] : to.split(',').map((s) => s.trim()).toList();
    final ccAddresses =
        cc.isEmpty ? <String>[] : cc.split(',').map((s) => s.trim()).toList();

    context.read<ComposeBloc>().add(ComposeSubmitted(
          mode: widget.mode,
          originalMessageId: widget.originalEmail?.id,
          toAddresses: toAddresses,
          ccAddresses: ccAddresses,
          subject: subject,
          body: body,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TitleBar(title: _title),
            Divider(height: 1, color: c.border),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _FieldRow(
                    label: 'To',
                    controller: _toController,
                    enabled: _toEditable,
                    hintText: 'recipient@example.com',
                  ),
                  const SizedBox(height: 8),
                  _FieldRow(
                    label: 'Cc',
                    controller: _ccController,
                    enabled: widget.mode == ComposeMode.newEmail,
                    hintText: 'cc@example.com',
                  ),
                  const SizedBox(height: 8),
                  _FieldRow(
                    label: 'Subject',
                    controller: _subjectController,
                    enabled: _subjectEditable,
                    hintText: 'Subject',
                  ),
                  const SizedBox(height: 12),
                  Divider(height: 1, color: c.border),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 240,
                    child: TextField(
                      controller: _bodyController,
                      focusNode: _bodyFocus,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 13,
                        height: 1.5,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Write your message here…',
                        hintStyle:
                            TextStyle(color: c.textMuted, fontSize: 13),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),
            _Footer(onSend: () => _submit(context)),
          ],
        ),
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: c.textMuted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.label,
    required this.controller,
    required this.enabled,
    required this.hintText,
  });

  final String label;
  final TextEditingController controller;
  final bool enabled;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 52,
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
          child: TextField(
            controller: controller,
            enabled: enabled,
            style: TextStyle(
              color: enabled ? c.textPrimary : c.textTertiary,
              fontSize: 13,
            ),
            decoration: InputDecoration(
              hintText: enabled ? hintText : null,
              hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.onSend});
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocBuilder<ComposeBloc, ComposeState>(
      builder: (context, state) {
        final isSending = state is ComposeSending;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed:
                    isSending ? null : () => Navigator.of(context).pop(),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: c.textMuted, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: isSending ? null : onSend,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: isSending
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded, size: 14),
                label: Text(
                  isSending ? 'Sending…' : 'Send',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
