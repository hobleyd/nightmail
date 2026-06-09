import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../injection_container.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/usecases/send_email.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/compose/compose_bloc.dart';
import '../blocs/compose/compose_event.dart';
import '../blocs/compose/compose_state.dart';
import 'recipient_input_field.dart';

class ComposeDialog extends StatelessWidget {
  const ComposeDialog({
    super.key,
    required this.mode,
    this.originalEmail,
    required this.fromAddress,
    this.accountId,
  });

  final ComposeMode mode;
  final Email? originalEmail;
  final String fromAddress;
  final String? accountId;

  static Future<void> show(
    BuildContext context, {
    required ComposeMode mode,
    Email? originalEmail,
  }) {
    final accountState = context.read<AccountCubit>().state;
    final fromAddress = accountState is AccountsLoaded
        ? accountState.activeAccount.emailAddress
        : '';
    final accountId =
        accountState is AccountsLoaded ? accountState.activeAccount.id : null;
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => BlocProvider(
        create: (_) => ComposeBloc(sendEmail: sl<SendEmail>()),
        child: ComposeDialog(
          mode: mode,
          originalEmail: originalEmail,
          fromAddress: fromAddress,
          accountId: accountId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).pop();
    return BlocListener<ComposeBloc, ComposeState>(
      listener: (listenerContext, state) {
        if (state is ComposeSent) {
          Navigator.of(listenerContext).pop();
          ScaffoldMessenger.of(listenerContext).showSnackBar(
            const SnackBar(
              content: Text('Email sent'),
              duration: Duration(seconds: 2),
            ),
          );
        } else if (state is ComposeError) {
          ScaffoldMessenger.of(listenerContext).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      },
      child: Dialog(
        backgroundColor: context.colors.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: ComposeForm(
          mode: mode,
          originalEmail: originalEmail,
          onClose: close,
          fromAddress: fromAddress,
          accountId: accountId,
        ),
      ),
    );
  }
}

class ComposeForm extends StatefulWidget {
  const ComposeForm({
    super.key,
    required this.mode,
    this.originalEmail,
    required this.onClose,
    required this.fromAddress,
    this.accountId,
    this.scrollable = false,
    this.onTitleChanged,
  });

  final ComposeMode mode;
  final Email? originalEmail;
  final VoidCallback onClose;
  final String fromAddress;
  final String? accountId;
  final bool scrollable;
  final ValueChanged<String>? onTitleChanged;

  @override
  State<ComposeForm> createState() => _ComposeFormState();
}

class _ComposeFormState extends State<ComposeForm> {
  late List<String> _toRecipients;
  late List<String> _ccRecipients;
  late final TextEditingController _fromController;
  late final TextEditingController _subjectController;
  late final TextEditingController _bodyController;
  final FocusNode _bodyFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _toRecipients = _parseAddresses(_initialTo());
    _ccRecipients = _parseAddresses(_initialCc());
    _fromController = TextEditingController(text: widget.fromAddress);
    _subjectController = TextEditingController(text: _initialSubject());
    _bodyController = TextEditingController();
    _subjectController.addListener(_onSubjectChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bodyFocus.requestFocus();
      widget.onTitleChanged?.call(_title);
    });
  }

  List<String> _parseAddresses(String text) {
    if (text.trim().isEmpty) return [];
    return text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
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

  static final _rePrefix = RegExp(r'^(?:re:\s*)+', caseSensitive: false);

  String _initialSubject() {
    final email = widget.originalEmail;
    if (email == null) return '';
    final subject = email.subject;
    return switch (widget.mode) {
      ComposeMode.reply ||
      ComposeMode.replyAll =>
        'Re: ${subject.replaceFirst(_rePrefix, '').trim()}',
      ComposeMode.forward => 'Fwd: $subject',
      ComposeMode.newEmail => '',
    };
  }

  @override
  void dispose() {
    _subjectController.removeListener(_onSubjectChanged);
    _fromController.dispose();
    _subjectController.dispose();
    _bodyController.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _onSubjectChanged() {
    setState(() {});
    widget.onTitleChanged?.call(_title);
  }

  String get _baseTitle => switch (widget.mode) {
        ComposeMode.newEmail => 'New Email',
        ComposeMode.reply => 'Reply',
        ComposeMode.replyAll => 'Reply All',
        ComposeMode.forward => 'Forward',
      };

  String get _title {
    final subject = _subjectController.text.trim();
    return subject.isNotEmpty ? subject : _baseTitle;
  }

  bool get _toInputEditable => switch (widget.mode) {
        ComposeMode.newEmail || ComposeMode.forward => true,
        _ => false,
      };

  bool get _ccInputEditable => widget.mode == ComposeMode.newEmail;

  bool get _subjectEditable => widget.mode == ComposeMode.newEmail;

  void _handleDrop(String address, String fromFieldId, String toFieldId) {
    if (fromFieldId == toFieldId) return;
    setState(() {
      if (fromFieldId == 'to') {
        _toRecipients = List.from(_toRecipients)..remove(address);
      } else {
        _ccRecipients = List.from(_ccRecipients)..remove(address);
      }
      if (toFieldId == 'to') {
        if (!_toRecipients.contains(address)) {
          _toRecipients = List.from(_toRecipients)..add(address);
        }
      } else {
        if (!_ccRecipients.contains(address)) {
          _ccRecipients = List.from(_ccRecipients)..add(address);
        }
      }
    });
  }

  void _submit(BuildContext context) {
    final to = _toRecipients;
    final cc = _ccRecipients;
    final subject = _subjectController.text.trim();
    final body = _bodyController.text.trim();

    if (body.isEmpty && widget.mode != ComposeMode.forward) {
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

    context.read<ComposeBloc>().add(ComposeSubmitted(
          mode: widget.mode,
          originalMessageId: widget.originalEmail?.id,
          toAddresses: to,
          ccAddresses: cc,
          subject: subject,
          body: body,
        ));
  }

  List<Widget> _buildFields(AppColors c, String? accountId) => [
        _FieldRow(
          label: 'From',
          controller: _fromController,
          enabled: false,
          hintText: '',
        ),
        const SizedBox(height: 8),
        RecipientInputField(
          label: 'To',
          fieldId: 'to',
          recipients: _toRecipients,
          onChanged: (r) => setState(() => _toRecipients = r),
          onDropAccepted: (address, fromFieldId) =>
              _handleDrop(address, fromFieldId, 'to'),
          showInput: _toInputEditable,
          hintText: 'recipient@example.com',
          accountId: accountId,
        ),
        const SizedBox(height: 8),
        RecipientInputField(
          label: 'Cc',
          fieldId: 'cc',
          recipients: _ccRecipients,
          onChanged: (r) => setState(() => _ccRecipients = r),
          onDropAccepted: (address, fromFieldId) =>
              _handleDrop(address, fromFieldId, 'cc'),
          showInput: _ccInputEditable,
          hintText: 'cc@example.com',
          accountId: accountId,
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
      ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accountId = widget.accountId;

    if (widget.scrollable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(title: _title, onClose: widget.onClose),
          Divider(height: 1, color: c.border),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ..._buildFields(c, accountId),
                  TextField(
                    controller: _bodyController,
                    focusNode: _bodyFocus,
                    maxLines: null,
                    minLines: 12,
                    textAlignVertical: TextAlignVertical.top,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 13,
                      height: 1.5,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Write your message here…',
                      hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: c.border),
          _Footer(onSend: () => _submit(context), onClose: widget.onClose),
        ],
      );
    }

    return SizedBox(
      width: 600,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(title: _title, onClose: widget.onClose),
          Divider(height: 1, color: c.border),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ..._buildFields(c, accountId),
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
                      hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          _Footer(onSend: () => _submit(context), onClose: widget.onClose),
        ],
      ),
    );
  }
}


// ---------------------------------------------------------------------------
// Supporting widgets
// ---------------------------------------------------------------------------

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.title, required this.onClose});
  final String title;
  final VoidCallback onClose;

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
            onPressed: onClose,
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: SizedBox(
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
        ),
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            maxLines: null,
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
  const _Footer({required this.onSend, required this.onClose});
  final VoidCallback onSend;
  final VoidCallback onClose;

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
                onPressed: isSending ? null : onClose,
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
