import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../injection_container.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_attachment.dart';
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
        ? () {
            final account = accountState.activeAccount;
            final name = account.displayName;
            final email = account.emailAddress;
            return name.isNotEmpty ? '$name <$email>' : email;
          }()
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
  List<String> _excludedAttachmentIds = [];

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

  bool get _toInputEditable => true;

  bool get _ccInputEditable => true;

  bool get _subjectEditable => true;

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
          excludedAttachmentIds: _excludedAttachmentIds,
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
      final isReplyLike = widget.mode == ComposeMode.reply ||
          widget.mode == ComposeMode.replyAll ||
          widget.mode == ComposeMode.forward;
      final quotedEmail = isReplyLike ? widget.originalEmail : null;
      final forwardEmail =
          widget.mode == ComposeMode.forward ? widget.originalEmail : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(title: _title, onClose: widget.onClose),
          Divider(height: 1, color: c.border),
          // Fields are fixed-height — kept outside the Expanded area so the
          // body + quoted-email section can grow freely when the window resizes.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _buildFields(c, accountId),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (forwardEmail != null &&
                      forwardEmail.attachments.isNotEmpty)
                    _ForwardAttachmentChips(
                      attachments: forwardEmail.attachments,
                      excludedIds: _excludedAttachmentIds,
                      onRemove: (id) => setState(
                          () => _excludedAttachmentIds = [
                                ..._excludedAttachmentIds,
                                id
                              ]),
                    ),
                  Expanded(
                    flex: 2,
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
                  if (quotedEmail != null)
                    Expanded(
                      flex: 3,
                      child: _ForwardedMessagePreview(
                        email: quotedEmail,
                        colors: c,
                        mode: widget.mode,
                        expand: true,
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

    final isReplyLike = widget.mode == ComposeMode.reply ||
        widget.mode == ComposeMode.replyAll ||
        widget.mode == ComposeMode.forward;
    final quotedEmail = isReplyLike ? widget.originalEmail : null;
    final forwardEmail =
        widget.mode == ComposeMode.forward ? widget.originalEmail : null;
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
                if (forwardEmail != null &&
                    forwardEmail.attachments.isNotEmpty)
                  _ForwardAttachmentChips(
                    attachments: forwardEmail.attachments,
                    excludedIds: _excludedAttachmentIds,
                    onRemove: (id) => setState(
                        () => _excludedAttachmentIds = [..._excludedAttachmentIds, id]),
                  ),
                SizedBox(
                  height: quotedEmail != null ? 150 : 240,
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
                if (quotedEmail != null)
                  _ForwardedMessagePreview(
                      email: quotedEmail, colors: c, mode: widget.mode),
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

class _ForwardAttachmentChips extends StatelessWidget {
  const _ForwardAttachmentChips({
    required this.attachments,
    required this.excludedIds,
    required this.onRemove,
  });

  final List<EmailAttachment> attachments;
  final List<String> excludedIds;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final visible =
        attachments.where((a) => !excludedIds.contains(a.id)).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: visible
            .map((att) => _AttachmentChip(
                  attachment: att,
                  onRemove: () => onRemove(att.id),
                ))
            .toList(),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment, required this.onRemove});

  final EmailAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceBase,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file, size: 12, color: c.textMuted),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              attachment.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.textPrimary),
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close, size: 12, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _ForwardedMessagePreview extends StatelessWidget {
  const _ForwardedMessagePreview({
    required this.email,
    required this.colors,
    required this.mode,
    this.expand = false,
  });

  final Email email;
  final AppColors colors;
  final ComposeMode mode;
  // When true the text body fills available height (Expanded layout).
  // When false it is capped at 220px (dialog layout).
  final bool expand;

  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<div[^>]*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</div>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const days = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final h = local.hour;
    final min = local.minute.toString().padLeft(2, '0');
    final amPm = h >= 12 ? 'PM' : 'AM';
    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '${days[local.weekday]}, ${months[local.month]} ${local.day}, '
        '${local.year} at $h12:$min $amPm';
  }

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final bodyText = email.bodyType == EmailBodyType.html
        ? _stripHtml(email.body)
        : email.body;
    final fromName = email.from.name;
    final from = (fromName != null && fromName.isNotEmpty)
        ? '$fromName <${email.from.address}>'
        : email.from.address;

    final List<Widget> headerLines;
    if (mode == ComposeMode.forward) {
      headerLines = [
        Text(
          '---------- Forwarded message ---------',
          style: TextStyle(
              color: c.textDimmed, fontSize: 12, fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 4),
        Text('From: $from',
            style: TextStyle(color: c.textDimmed, fontSize: 12)),
        Text('Subject: ${email.subject}',
            style: TextStyle(color: c.textDimmed, fontSize: 12)),
      ];
    } else {
      headerLines = [
        Text(
          'On ${_formatDate(email.receivedDateTime)}, $from wrote:',
          style: TextStyle(
              color: c.textDimmed, fontSize: 12, fontStyle: FontStyle.italic),
        ),
      ];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Divider(height: 1, color: c.border),
        const SizedBox(height: 12),
        ...headerLines,
        const SizedBox(height: 8),
        if (expand)
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                bodyText,
                style: TextStyle(
                    color: c.textSecondary, fontSize: 12, height: 1.5),
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: Text(
                bodyText,
                style: TextStyle(
                    color: c.textSecondary, fontSize: 12, height: 1.5),
              ),
            ),
          ),
        const SizedBox(height: 12),
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
