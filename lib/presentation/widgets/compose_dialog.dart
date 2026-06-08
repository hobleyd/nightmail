import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/contact_suggestion.dart';
import '../../domain/entities/email.dart';
import '../../domain/repositories/system_contacts_repository.dart';
import '../../domain/usecases/search_contacts.dart';
import '../../domain/usecases/send_email.dart';
import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/compose/compose_bloc.dart';
import '../blocs/compose/compose_event.dart';
import '../blocs/compose/compose_state.dart';

typedef _RecipientDrag = ({String address, String sourceFieldId});

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
        _RecipientField(
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
        _RecipientField(
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
// Recipient field
// ---------------------------------------------------------------------------

class _RecipientField extends StatefulWidget {
  const _RecipientField({
    required this.label,
    required this.fieldId,
    required this.recipients,
    required this.onChanged,
    required this.onDropAccepted,
    this.showInput = false,
    this.hintText,
    this.accountId,
  });

  final String label;
  final String fieldId;
  final List<String> recipients;
  final ValueChanged<List<String>> onChanged;
  final void Function(String address, String fromFieldId) onDropAccepted;
  final bool showInput;
  final String? hintText;
  final String? accountId;

  @override
  State<_RecipientField> createState() => _RecipientFieldState();
}

class _RecipientFieldState extends State<_RecipientField> {
  int? _selectedIndex;
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final FocusNode _chipKeyFocus = FocusNode();

  // Typeahead
  final _layerLink = LayerLink();
  final _overlayController = OverlayPortalController();
  List<ContactSuggestion> _suggestions = [];
  int _suggestionIndex = -1;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(_onInputFocusChanged);
    if (widget.showInput && widget.accountId != null) {
      // Eagerly request contacts permission and pre-load the cache so the
      // permission dialog appears as soon as the compose form is shown.
      sl<SystemContactsRepository>()
          .warmUp()
          .catchError((e) => debugPrint('[NightMail] contacts warmUp: $e'));
    }
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
    _searchDebounce?.cancel();
    _inputController.dispose();
    _inputFocus.removeListener(_onInputFocusChanged);
    _inputFocus.dispose();
    _chipKeyFocus.dispose();
    super.dispose();
  }

  void _onInputFocusChanged() {
    if (!_inputFocus.hasFocus) {
      _flushInput();
      _clearSuggestions();
    }
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

  void _onTextChanged(String val) {
    if (val.endsWith(',') || val.endsWith(';')) {
      _flushInput();
      _clearSuggestions();
      return;
    }

    _searchDebounce?.cancel();
    final trimmed = val.trim();

    if (trimmed.isEmpty) {
      _clearSuggestions();
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 200), () async {
      if (!mounted) return;
      final query = _inputController.text.trim();
      if (query.isEmpty) return;
      final accountId = widget.accountId;
      if (accountId == null) return;

      try {
        final results = await sl<SearchContacts>().call(
          query: query,
          accountId: accountId,
        );
        if (mounted) _setSuggestions(results);
      } catch (e) {
        debugPrint('[NightMail] recipient search error: $e');
      }
    });
  }

  void _clearSuggestions() {
    if (!mounted || _suggestions.isEmpty) return;
    setState(() {
      _suggestions = [];
      _suggestionIndex = -1;
    });
    if (_overlayController.isShowing) _overlayController.hide();
  }

  void _setSuggestions(List<ContactSuggestion> suggestions) {
    setState(() {
      _suggestions = suggestions;
      _suggestionIndex = -1;
    });
    if (suggestions.isNotEmpty) {
      if (!_overlayController.isShowing) _overlayController.show();
    } else {
      if (_overlayController.isShowing) _overlayController.hide();
    }
  }

  void _addSuggestion(ContactSuggestion s) {
    final newList = List<String>.from(widget.recipients)..add(s.displayText);
    _inputController.clear();
    _clearSuggestions();
    widget.onChanged(newList);
    _inputFocus.requestFocus();
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
                                if (event is! KeyDownEvent) {
                                  return KeyEventResult.ignored;
                                }
                                if (_suggestions.isNotEmpty) {
                                  if (event.logicalKey ==
                                      LogicalKeyboardKey.arrowDown) {
                                    setState(() => _suggestionIndex =
                                        (_suggestionIndex + 1)
                                            .clamp(0, _suggestions.length - 1));
                                    return KeyEventResult.handled;
                                  }
                                  if (event.logicalKey ==
                                      LogicalKeyboardKey.arrowUp) {
                                    setState(() => _suggestionIndex =
                                        (_suggestionIndex - 1)
                                            .clamp(-1, _suggestions.length - 1));
                                    return KeyEventResult.handled;
                                  }
                                  if (event.logicalKey ==
                                      LogicalKeyboardKey.escape) {
                                    _clearSuggestions();
                                    return KeyEventResult.handled;
                                  }
                                  if (event.logicalKey ==
                                          LogicalKeyboardKey.enter &&
                                      _suggestionIndex >= 0) {
                                    _addSuggestion(
                                        _suggestions[_suggestionIndex]);
                                    return KeyEventResult.handled;
                                  }
                                }
                                if (event.logicalKey ==
                                        LogicalKeyboardKey.backspace &&
                                    _inputController.text.isEmpty &&
                                    widget.recipients.isNotEmpty) {
                                  _selectChip(widget.recipients.length - 1);
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: OverlayPortal(
                                controller: _overlayController,
                                overlayChildBuilder: (ctx) => Align(
                                  alignment: Alignment.topLeft,
                                  child: CompositedTransformFollower(
                                    link: _layerLink,
                                    showWhenUnlinked: false,
                                    targetAnchor: Alignment.bottomLeft,
                                    followerAnchor: Alignment.topLeft,
                                    child: _SuggestionDropdown(
                                      suggestions: _suggestions,
                                      selectedIndex: _suggestionIndex,
                                      onSelect: _addSuggestion,
                                    ),
                                  ),
                                ),
                                child: CompositedTransformTarget(
                                  link: _layerLink,
                                  child: TextField(
                                    controller: _inputController,
                                    focusNode: _inputFocus,
                                    style: TextStyle(
                                      color: c.textPrimary,
                                      fontSize: 13,
                                    ),
                                    onSubmitted: (_) => _flushInput(),
                                    onChanged: _onTextChanged,
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

// ---------------------------------------------------------------------------
// Suggestion dropdown
// ---------------------------------------------------------------------------

class _SuggestionDropdown extends StatelessWidget {
  const _SuggestionDropdown({
    required this.suggestions,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<ContactSuggestion> suggestions;
  final int selectedIndex;
  final ValueChanged<ContactSuggestion> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.surfacePanel,
      elevation: 8,
      borderRadius: BorderRadius.circular(6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 248),
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: suggestions.length,
          separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
          itemBuilder: (ctx, i) {
            final s = suggestions[i];
            final hasName = s.name != null && s.name!.isNotEmpty;
            return ListTile(
              dense: true,
              selected: i == selectedIndex,
              selectedTileColor: AppColors.accent.withAlpha(40),
              hoverColor: AppColors.accent.withAlpha(20),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              visualDensity: VisualDensity.compact,
              title: Text(
                hasName ? s.name! : s.address,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 13,
                  fontWeight:
                      hasName ? FontWeight.w500 : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: hasName
                  ? Text(
                      s.address,
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              onTap: () => onSelect(s),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Recipient chip
// ---------------------------------------------------------------------------

class _RecipientChip extends StatelessWidget {
  const _RecipientChip({
    required this.address,
    required this.isSelected,
    this.opacity = 1.0,
  });

  final String address;
  final bool isSelected;
  final double opacity;

  // Show just the name portion from "Name <email>" formatted strings.
  static final _nameRe = RegExp(r'^(.+?)\s*<[^>]+>\s*$');

  String get _label {
    final m = _nameRe.firstMatch(address);
    return m != null ? m.group(1)!.trim() : address;
  }

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
          _label,
          style: TextStyle(
            color: isSelected ? AppColors.accent : c.textSecondary,
            fontSize: 12,
          ),
        ),
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
