import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/contact_suggestion.dart';
import '../../domain/repositories/system_contacts_repository.dart';
import '../../domain/usecases/search_contacts.dart';
import '../../injection_container.dart';

typedef RecipientDropAccepted = void Function(String address, String fromFieldId);

typedef _RecipientDrag = ({String address, String sourceFieldId});

/// Chip-based multi-recipient input with contact typeahead.
///
/// Provide [accountId] to enable full search (sender cache + system contacts).
/// Provide [fieldId] and [onDropAccepted] to enable drag-and-drop between fields.
class RecipientInputField extends StatefulWidget {
  const RecipientInputField({
    super.key,
    required this.label,
    required this.recipients,
    required this.onChanged,
    this.labelWidth = 52,
    this.hintText,
    this.accountId,
    this.showInput = true,
    this.fieldId,
    this.onDropAccepted,
  }) : assert(
          fieldId == null || onDropAccepted != null,
          'onDropAccepted is required when fieldId is set',
        );

  final String label;
  final double labelWidth;
  final List<String> recipients;
  final ValueChanged<List<String>> onChanged;
  final String? hintText;
  final String? accountId;
  final bool showInput;
  final String? fieldId;
  final RecipientDropAccepted? onDropAccepted;

  @override
  State<RecipientInputField> createState() => RecipientInputFieldState();
}

class RecipientInputFieldState extends State<RecipientInputField> {
  int? _selectedIndex;
  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  final _chipKeyFocus = FocusNode();

  final _layerLink = LayerLink();
  final _overlayController = OverlayPortalController();
  List<ContactSuggestion> _suggestions = [];
  int _suggestionIndex = -1;
  Timer? _searchDebounce;
  bool _suppressNextFocusLoss = false;

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(_onInputFocusChanged);
    if (widget.showInput && widget.accountId != null) {
      sl<SystemContactsRepository>()
          .warmUp()
          .catchError((e) => debugPrint('[NightMail] contacts warmUp: $e'));
    }
  }

  @override
  void didUpdateWidget(RecipientInputField old) {
    super.didUpdateWidget(old);
    if (_selectedIndex != null && _selectedIndex! >= widget.recipients.length) {
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
      if (_suppressNextFocusLoss) {
        _suppressNextFocusLoss = false;
        return;
      }
      _flushInput();
      _clearSuggestions();
    }
  }

  void flush() => _flushInput();

  void _flushInput() {
    final text = _inputController.text
        .trim()
        .replaceAll(',', '')
        .replaceAll(';', '');
    if (text.isEmpty) return;
    widget.onChanged(List.from(widget.recipients)..add(text));
    _inputController.clear();
  }

  void _selectChip(int index) {
    setState(() => _selectedIndex = index);
    _chipKeyFocus.requestFocus();
  }

  void _deleteSelected() {
    final idx = _selectedIndex;
    if (idx == null) return;
    widget.onChanged(List.from(widget.recipients)..removeAt(idx));
    setState(() => _selectedIndex = null);
    if (widget.showInput) _inputFocus.requestFocus();
  }

  void _onTextChanged(String val) {
    if (val.endsWith(',') || val.endsWith(';')) {
      _flushInput();
      _clearSuggestions();
      return;
    }
    _searchDebounce?.cancel();
    if (val.trim().isEmpty) {
      _clearSuggestions();
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 200), () async {
      if (!mounted) return;
      final query = _inputController.text.trim();
      if (query.isEmpty) return;
      try {
        final List<ContactSuggestion> results;
        final accountId = widget.accountId;
        if (accountId != null) {
          results = await sl<SearchContacts>().call(
            query: query,
            accountId: accountId,
          );
        } else {
          results = await sl<SystemContactsRepository>().search(query);
        }
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
    widget.onChanged(List.from(widget.recipients)..add(s.displayText));
    _inputController.clear();
    _clearSuggestions();
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
            width: widget.labelWidth,
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
            onKeyEvent: (_, event) {
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
            child: _buildInputArea(c),
          ),
        ),
      ],
    );
  }

  Widget _buildInputArea(AppColors c) {
    final fieldId = widget.fieldId;
    if (fieldId == null) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          setState(() => _selectedIndex = null);
          if (widget.showInput) _inputFocus.requestFocus();
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 28),
          child: _buildWrap(c, draggable: false),
        ),
      );
    }

    return DragTarget<_RecipientDrag>(
      onWillAcceptWithDetails: (details) =>
          details.data.sourceFieldId != fieldId,
      onAcceptWithDetails: (details) => widget.onDropAccepted!(
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
                    border: Border.all(color: AppColors.accent.withAlpha(60)),
                  )
                : null,
            child: _buildWrap(c, draggable: true),
          ),
        );
      },
    );
  }

  Widget _buildWrap(AppColors c, {required bool draggable}) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (int i = 0; i < widget.recipients.length; i++)
          _buildChip(i, c, draggable: draggable),
        if (widget.showInput)
          IntrinsicWidth(
            child: Focus(
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (_suggestions.isNotEmpty) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    setState(() => _suggestionIndex =
                        (_suggestionIndex + 1)
                            .clamp(0, _suggestions.length - 1));
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    setState(() => _suggestionIndex =
                        (_suggestionIndex - 1)
                            .clamp(-1, _suggestions.length - 1));
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.escape) {
                    _clearSuggestions();
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.enter &&
                      _suggestionIndex >= 0) {
                    _addSuggestion(_suggestions[_suggestionIndex]);
                    return KeyEventResult.handled;
                  }
                }
                if (event.logicalKey == LogicalKeyboardKey.backspace &&
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
                    child: Listener(
                      onPointerDown: (_) => _suppressNextFocusLoss = true,
                      child: _SuggestionDropdown(
                        suggestions: _suggestions,
                        selectedIndex: _suggestionIndex,
                        onSelect: _addSuggestion,
                      ),
                    ),
                  ),
                ),
                child: CompositedTransformTarget(
                  link: _layerLink,
                  child: TextField(
                    controller: _inputController,
                    focusNode: _inputFocus,
                    style: TextStyle(color: c.textPrimary, fontSize: 13),
                    onSubmitted: (_) => _flushInput(),
                    onChanged: _onTextChanged,
                    decoration: InputDecoration(
                      hintText:
                          widget.recipients.isEmpty ? widget.hintText : null,
                      hintStyle:
                          TextStyle(color: c.textMuted, fontSize: 13),
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
    );
  }

  Widget _buildChip(int index, AppColors c, {required bool draggable}) {
    final address = widget.recipients[index];
    final isSelected = _selectedIndex == index;

    if (!draggable) {
      return GestureDetector(
        onTap: () => _selectChip(index),
        child: _RecipientChip(address: address, isSelected: isSelected),
      );
    }

    return Draggable<_RecipientDrag>(
      data: (address: address, sourceFieldId: widget.fieldId!),
      feedback: Material(
        color: Colors.transparent,
        child: _RecipientChip(address: address, isSelected: true, opacity: 0.85),
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
            color: isSelected ? AppColors.accent : c.separatorStrong,
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
