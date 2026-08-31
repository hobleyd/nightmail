import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html_view/html_view.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/contact_suggestion.dart';
import '../../domain/repositories/system_contacts_repository.dart';
import '../../domain/usecases/search_contacts.dart';
import '../../injection_container.dart';
import 'anchored_dropdown.dart';

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
    this.accountDomain,
    this.showInput = true,
    this.fieldId,
    this.onDropAccepted,
    this.onTabToNext,
    this.chipBadgeBuilder,
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
  final String? accountDomain;
  final bool showInput;
  final String? fieldId;
  final RecipientDropAccepted? onDropAccepted;
  /// Called when Tab is pressed in the input with no suggestion dropdown
  /// open, so the caller can move focus to the next field in a fixed order
  /// instead of relying on default focus traversal.
  final VoidCallback? onTabToNext;

  /// Optional per-chip trailing marker, rendered inside the chip after the
  /// label. Return null for no marker. Lets a caller annotate a chip with
  /// state it owns (e.g. a meeting guest's acceptance tick) without this
  /// widget knowing anything about that state.
  final Widget? Function(String address)? chipBadgeBuilder;

  @override
  State<RecipientInputField> createState() => RecipientInputFieldState();
}

class RecipientInputFieldState extends State<RecipientInputField> {
  int? _selectedIndex;
  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  final _chipKeyFocus = FocusNode();

  final _layerLink = LayerLink();

  /// On the [CompositedTransformTarget], so the dropdown can measure where the
  /// input has ended up in the wrap and shift itself off the window edge.
  final _targetKey = GlobalKey();
  final _overlayController = OverlayPortalController();
  List<ContactSuggestion> _suggestions = [];
  int _suggestionIndex = -1;
  Timer? _searchDebounce;

  /// Incremented per dispatched search; a result is only applied if its id is
  /// still the latest, so out-of-order responses are dropped.
  int _searchRequestId = 0;
  bool _suppressNextFocusLoss = false;

  /// Whether this field currently holds [HtmlViewOverlayGuard]. The dropdown is
  /// an [OverlayPortal], not a [ModalRoute], so nothing else tells the compose
  /// body's native WebView2 to get out of the way — and on Windows that HWND
  /// always paints over Flutter, swallowing the list.
  bool _guardAcquired = false;

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
    _releaseGuard();
    _inputController.dispose();
    _inputFocus.removeListener(_onInputFocusChanged);
    _inputFocus.dispose();
    _chipKeyFocus.dispose();
    super.dispose();
  }

  void _onInputFocusChanged() {
    // Typing is not acting on a chip. The field's own tap clears the selection,
    // but a tap that lands on the TextField is taken by the TextField and never
    // reaches it — and the chip-key Focus is an *ancestor* of that TextField,
    // so a stale selection would still answer Delete and remove a chip the user
    // had clicked away from.
    if (_inputFocus.hasFocus) {
      if (_selectedIndex != null) setState(() => _selectedIndex = null);
      return;
    }
    if (_suppressNextFocusLoss) {
      _suppressNextFocusLoss = false;
      return;
    }
    _flushInput();
    _clearSuggestions();
  }

  void flush() => _flushInput();

  void requestFocus() => _inputFocus.requestFocus();

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
      // Cancelling the debounce timer does not cancel a search already
      // awaiting, so tag each one: without this a slow lookup (the live
      // fallback before the contact cache has been populated) can land after a
      // newer, faster one and repopulate the dropdown with results for a query
      // the user has already typed past.
      final requestId = ++_searchRequestId;
      try {
        final List<ContactSuggestion> results;
        final accountId = widget.accountId;
        if (accountId != null) {
          results = await sl<SearchContacts>().call(
            query: query,
            accountId: accountId,
            accountDomain: widget.accountDomain,
          );
        } else {
          results = await sl<SystemContactsRepository>().search(query);
        }
        if (mounted && requestId == _searchRequestId) _setSuggestions(results);
      } catch (e) {
        debugPrint('[NightMail] recipient search error: $e');
      }
    });
  }

  /// Held for as long as the dropdown is up, not per keystroke: both calls are
  /// idempotent, so a run of keystrokes keeps the count at one and the body
  /// editor doesn't flicker back and forth between letters.
  void _acquireGuard() {
    if (_guardAcquired) return;
    HtmlViewOverlayGuard.acquire();
    _guardAcquired = true;
  }

  void _releaseGuard() {
    if (!_guardAcquired) return;
    HtmlViewOverlayGuard.release();
    _guardAcquired = false;
  }

  void _clearSuggestions() {
    if (!mounted) return;
    _releaseGuard();
    if (_suggestions.isEmpty) return;
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
      _acquireGuard();
      if (!_overlayController.isShowing) _overlayController.show();
    } else {
      _releaseGuard();
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
                  if (event.logicalKey == LogicalKeyboardKey.tab) {
                    _addSuggestion(
                        _suggestions[_suggestionIndex >= 0 ? _suggestionIndex : 0]);
                    return KeyEventResult.handled;
                  }
                }
                if (event.logicalKey == LogicalKeyboardKey.backspace &&
                    _inputController.text.isEmpty &&
                    widget.recipients.isNotEmpty) {
                  _selectChip(widget.recipients.length - 1);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.tab &&
                    widget.onTabToNext != null) {
                  _flushInput();
                  widget.onTabToNext!();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: OverlayPortal(
                controller: _overlayController,
                overlayChildBuilder: (ctx) => AnchoredDropdown(
                  link: _layerLink,
                  targetKey: _targetKey,
                  preferredWidth: _kSuggestionDropdownWidth,
                  onPointerDown: () => _suppressNextFocusLoss = true,
                  builder: (_, maxWidth) => _SuggestionDropdown(
                    suggestions: _suggestions,
                    selectedIndex: _suggestionIndex,
                    onSelect: _addSuggestion,
                    maxWidth: maxWidth,
                  ),
                ),
                child: CompositedTransformTarget(
                  key: _targetKey,
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
    final badge = widget.chipBadgeBuilder?.call(address);

    // Selection is taken on pointer *down*, through a Listener rather than a
    // tap. A chip is a Draggable, and `ImmediateMultiDragGestureRecognizer`
    // hard-codes its hit slop to one logical pixel for a mouse
    // (`kPrecisePointerHitSlop`) — so a click that drifts, which a trackpad
    // click nearly always does, wins the arena and the tap never fires. The
    // chip was then never selected and Delete had nothing to act on, while a
    // perfectly still click worked: the bug that looked intermittent.
    //
    // A Listener sits outside the arena, so nothing can take the press from
    // it. Selecting on press is also what a desktop list does anyway.
    //
    // The tap handler still has to be here as well, doing the same thing. It
    // is not for selecting — the Listener has already done that — but to keep
    // the *field's* own tap, which clears the selection, from winning the
    // arena and undoing it on the way back up. That is what the chip's tap
    // was quietly doing before.
    final Widget chip = Listener(
      onPointerDown: (_) => _selectChip(index),
      child: GestureDetector(
        onTap: () => _selectChip(index),
        child: _RecipientChip(
          address: address,
          isSelected: isSelected,
          badge: badge,
        ),
      ),
    );

    if (!draggable) return chip;

    return Draggable<_RecipientDrag>(
      data: (address: address, sourceFieldId: widget.fieldId!),
      // A drag that lands somewhere takes this chip out of the list, and the
      // index would then name whichever recipient shuffled up into its place.
      // A drag that is dropped nowhere leaves the list alone, so that one
      // keeps its selection — it was a click as far as the user is concerned.
      onDragCompleted: () {
        if (mounted) setState(() => _selectedIndex = null);
      },
      feedback: Material(
        color: Colors.transparent,
        child: _RecipientChip(
          address: address,
          isSelected: true,
          opacity: 0.85,
          badge: badge,
        ),
      ),
      childWhenDragging: _RecipientChip(
        address: address,
        isSelected: isSelected,
        opacity: 0.35,
        badge: badge,
      ),
      child: chip,
    );
  }
}

// ---------------------------------------------------------------------------
// Suggestion dropdown
// ---------------------------------------------------------------------------

/// Width the suggestion panel is drawn at when the window has room for it.
const double _kSuggestionDropdownWidth = 400;

class _SuggestionDropdown extends StatelessWidget {
  const _SuggestionDropdown({
    required this.suggestions,
    required this.selectedIndex,
    required this.onSelect,
    required this.maxWidth,
  });

  final List<ContactSuggestion> suggestions;
  final int selectedIndex;
  final ValueChanged<ContactSuggestion> onSelect;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.surfacePanel,
      elevation: 8,
      borderRadius: BorderRadius.circular(6),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: 248),
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
    this.badge,
  });

  final String address;
  final bool isSelected;
  final double opacity;
  final Widget? badge;

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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label,
              style: TextStyle(
                color: isSelected ? AppColors.accent : c.textSecondary,
                fontSize: 12,
              ),
            ),
            if (badge != null) ...[const SizedBox(width: 4), badge!],
          ],
        ),
      ),
    );
  }
}
