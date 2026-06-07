import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/usecases/send_email.dart';
import '../../injection_container.dart';
import '../blocs/compose/compose_bloc.dart';
import '../blocs/compose/compose_event.dart';
import '../blocs/compose/compose_state.dart';

typedef _RecipientDrag = ({String address, String sourceFieldId});

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
  late List<String> _toRecipients;
  late List<String> _ccRecipients;
  late final TextEditingController _subjectController;
  late final TextEditingController _bodyController;
  final FocusNode _bodyFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _toRecipients = _parseAddresses(_initialTo());
    _ccRecipients = _parseAddresses(_initialCc());
    _subjectController = TextEditingController(text: _initialSubject());
    _bodyController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bodyFocus.requestFocus();
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
                  _RecipientField(
                    label: 'To',
                    fieldId: 'to',
                    recipients: _toRecipients,
                    onChanged: (r) => setState(() => _toRecipients = r),
                    onDropAccepted: (address, fromFieldId) =>
                        _handleDrop(address, fromFieldId, 'to'),
                    showInput: _toInputEditable,
                    hintText: 'recipient@example.com',
                  ),
                  const SizedBox(height: 8),
                  _RecipientField(
                    label: 'Cc',
                    fieldId: 'cc',
                    recipients: _ccRecipients,
                    onChanged: (r) => setState(() => _ccRecipients = r),
                    onDropAccepted: (address, fromFieldId) =>
                        _handleDrop(address, fromFieldId, 'cc'),
                    showInput: _ccInputEditable,
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

class _RecipientField extends StatefulWidget {
  const _RecipientField({
    required this.label,
    required this.fieldId,
    required this.recipients,
    required this.onChanged,
    required this.onDropAccepted,
    this.showInput = false,
    this.hintText,
  });

  final String label;
  final String fieldId;
  final List<String> recipients;
  final ValueChanged<List<String>> onChanged;
  final void Function(String address, String fromFieldId) onDropAccepted;
  final bool showInput;
  final String? hintText;

  @override
  State<_RecipientField> createState() => _RecipientFieldState();
}

class _RecipientFieldState extends State<_RecipientField> {
  int? _selectedIndex;
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final FocusNode _chipKeyFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(_onInputFocusChanged);
  }

  @override
  void didUpdateWidget(_RecipientField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedIndex != null &&
        _selectedIndex! >= widget.recipients.length) {
      _selectedIndex = null;
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus.removeListener(_onInputFocusChanged);
    _inputFocus.dispose();
    _chipKeyFocus.dispose();
    super.dispose();
  }

  void _onInputFocusChanged() {
    if (!_inputFocus.hasFocus) _flushInput();
  }

  void _flushInput() {
    final text = _inputController.text
        .trim()
        .replaceAll(',', '')
        .replaceAll(';', '');
    if (text.isEmpty) return;
    final newList = List<String>.from(widget.recipients)..add(text);
    _inputController.clear();
    widget.onChanged(newList);
  }

  void _selectChip(int index) {
    setState(() => _selectedIndex = index);
    _chipKeyFocus.requestFocus();
  }

  void _deleteSelected() {
    final idx = _selectedIndex;
    if (idx == null) return;
    final newList = List<String>.from(widget.recipients)..removeAt(idx);
    setState(() => _selectedIndex = null);
    widget.onChanged(newList);
    if (widget.showInput) _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: SizedBox(
            width: 52,
            child: Text(
              widget.label,
              style: TextStyle(
                color: c.textDimmed,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        Expanded(
          child: Focus(
            focusNode: _chipKeyFocus,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent || _selectedIndex == null) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.backspace ||
                  event.logicalKey == LogicalKeyboardKey.delete) {
                _deleteSelected();
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.escape) {
                setState(() => _selectedIndex = null);
                if (widget.showInput) _inputFocus.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: DragTarget<_RecipientDrag>(
              onWillAcceptWithDetails: (details) =>
                  details.data.sourceFieldId != widget.fieldId,
              onAcceptWithDetails: (details) => widget.onDropAccepted(
                details.data.address,
                details.data.sourceFieldId,
              ),
              builder: (context, candidateData, _) {
                final isHovering = candidateData.isNotEmpty;
                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    setState(() => _selectedIndex = null);
                    if (widget.showInput) _inputFocus.requestFocus();
                  },
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 28),
                    decoration: isHovering
                        ? BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: AppColors.accent.withAlpha(20),
                            border: Border.all(
                              color: AppColors.accent.withAlpha(60),
                            ),
                          )
                        : null,
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (int i = 0; i < widget.recipients.length; i++)
                          _buildChip(i, c),
                        if (widget.showInput)
                          IntrinsicWidth(
                            child: Focus(
                              onKeyEvent: (node, event) {
                                if (event is KeyDownEvent &&
                                    event.logicalKey ==
                                        LogicalKeyboardKey.backspace &&
                                    _inputController.text.isEmpty &&
                                    widget.recipients.isNotEmpty) {
                                  _selectChip(widget.recipients.length - 1);
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: TextField(
                                controller: _inputController,
                                focusNode: _inputFocus,
                                style: TextStyle(
                                  color: c.textPrimary,
                                  fontSize: 13,
                                ),
                                onSubmitted: (_) => _flushInput(),
                                onChanged: (val) {
                                  if (val.endsWith(',') ||
                                      val.endsWith(';')) {
                                    _flushInput();
                                  }
                                },
                                decoration: InputDecoration(
                                  hintText: widget.recipients.isEmpty
                                      ? widget.hintText
                                      : null,
                                  hintStyle: TextStyle(
                                    color: c.textMuted,
                                    fontSize: 13,
                                  ),
                                  border: InputBorder.none,
                                  contentPadding: EdgeInsets.zero,
                                  isDense: true,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChip(int index, AppColors c) {
    final address = widget.recipients[index];
    final isSelected = _selectedIndex == index;

    return Draggable<_RecipientDrag>(
      data: (address: address, sourceFieldId: widget.fieldId),
      feedback: Material(
        color: Colors.transparent,
        child: _RecipientChip(
          address: address,
          isSelected: true,
          opacity: 0.85,
        ),
      ),
      childWhenDragging: _RecipientChip(
        address: address,
        isSelected: isSelected,
        opacity: 0.35,
      ),
      child: GestureDetector(
        onTap: () => _selectChip(index),
        child: _RecipientChip(address: address, isSelected: isSelected),
      ),
    );
  }
}

class _RecipientChip extends StatelessWidget {
  const _RecipientChip({
    required this.address,
    required this.isSelected,
    this.opacity = 1.0,
  });

  final String address;
  final bool isSelected;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Opacity(
      opacity: opacity,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accent.withAlpha(30) : c.separator,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? AppColors.accent
                : c.separatorStrong,
          ),
        ),
        child: Text(
          address,
          style: TextStyle(
            color: isSelected ? AppColors.accent : c.textSecondary,
            fontSize: 12,
          ),
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
