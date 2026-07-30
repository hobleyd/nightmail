import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';

// ─── Shared date/time entry fields ───────────────────────────────────────────
//
// The event editor and the reading pane's "propose new time" banner both edit
// a start/end pair, so they share these fields: a date button that opens the
// material date picker, and an editable time combo box.

/// Half-hour slots for the day, offset to land on [anchor]'s minute so the
/// list reads as "30-minute increments from the current value" (e.g. an
/// anchor of 3:45 yields ...3:45, 4:15, 4:45... rather than always :00/:30).
List<TimeOfDay> timeSlotsAnchoredTo(TimeOfDay anchor) {
  final offset = anchor.minute % 30;
  return [
    for (int h = 0; h < 24; h++)
      for (final m in [offset, offset + 30]) TimeOfDay(hour: h, minute: m),
  ];
}

String formatTimeOfDay(TimeOfDay t) =>
    DateFormat('h:mm a').format(DateTime(2000, 1, 1, t.hour, t.minute));

/// Parses free-typed time text like "9", "9:30", "930pm", "17:30".
/// When no am/pm suffix is given and the hour is ambiguous (1-12), the
/// meridiem of [previous] is preserved (so typing "9" on a 9:00 PM field
/// stays PM). Returns null when the text can't be parsed as a time.
TimeOfDay? parseTimeOfDay(String raw, TimeOfDay previous) {
  final text = raw.trim().toLowerCase();
  if (text.isEmpty) return null;
  final match = RegExp(r'^(\d{1,2}):?(\d{2})?\s*(am|pm)?$').firstMatch(text);
  if (match == null) return null;

  var hour = int.parse(match.group(1)!);
  final minute = match.group(2) != null ? int.parse(match.group(2)!) : 0;
  final meridiem = match.group(3);
  if (minute > 59) return null;

  if (meridiem != null) {
    if (hour < 1 || hour > 12) return null;
    hour = hour % 12;
    if (meridiem == 'pm') hour += 12;
  } else if (hour >= 1 && hour <= 12) {
    final wasPm = previous.hour >= 12;
    hour = hour % 12;
    if (wasPm) hour += 12;
  } else if (hour > 23) {
    return null;
  }
  return TimeOfDay(hour: hour, minute: minute);
}

class DateFieldButton extends StatelessWidget {
  const DateFieldButton({super.key, required this.date, required this.onTap});
  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: c.separator,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          DateFormat('EEE, MMM d, yyyy').format(date),
          style: TextStyle(color: c.textPrimary, fontSize: 12),
        ),
      ),
    );
  }
}

class TimeFieldButton extends StatelessWidget {
  const TimeFieldButton({super.key, required this.time, required this.onTap});
  final TimeOfDay time;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dt = DateTime(2000, 1, 1, time.hour, time.minute);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: c.separator,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          DateFormat('h:mm a').format(dt),
          style: TextStyle(color: c.textPrimary, fontSize: 12),
        ),
      ),
    );
  }
}

// ─── Editable time combo box ───────────────────────────────────────────────
//
// A text field that opens an overlay dropdown of half-hour time slots
// (12:00 AM .. 11:30 PM) anchored below it, scrolled to the field's current
// value. The user can click a slot or type any time directly (e.g. "9:17am",
// "930", "17:30"); unparseable input reverts to the previous value on blur.

class TimeComboBox extends StatefulWidget {
  const TimeComboBox({
    super.key,
    required this.time,
    required this.onChanged,
  });
  final TimeOfDay time;
  final ValueChanged<TimeOfDay> onChanged;

  @override
  State<TimeComboBox> createState() => _TimeComboBoxState();
}

class _TimeComboBoxState extends State<TimeComboBox> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();
  final _layerLink = LayerLink();
  final _overlayController = OverlayPortalController();
  final _scrollController = ScrollController();
  // Full day of slots anchored to the value the field had when the dropdown
  // was last opened, and the (possibly typed-filtered) subset shown.
  List<TimeOfDay> _daySlots = const [];
  List<TimeOfDay> _filteredSlots = const [];
  int _highlightIndex = -1;
  bool _suppressNextFocusLoss = false;

  static const double _rowHeight = 30;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: formatTimeOfDay(widget.time));
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(TimeComboBox old) {
    super.didUpdateWidget(old);
    if (!_focusNode.hasFocus && old.time != widget.time) {
      _controller.text = formatTimeOfDay(widget.time);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) {
      _openDropdown();
      _controller.selection = TextSelection(
          baseOffset: 0, extentOffset: _controller.text.length);
      return;
    }
    if (_suppressNextFocusLoss) {
      _suppressNextFocusLoss = false;
      return;
    }
    _commit();
    _closeDropdown();
  }

  void _openDropdown() {
    final slots = timeSlotsAnchoredTo(widget.time);
    setState(() {
      _daySlots = slots;
      _filteredSlots = slots;
      _highlightIndex = slots.indexWhere(
          (s) => s.hour == widget.time.hour && s.minute == widget.time.minute);
    });
    if (!_overlayController.isShowing) _overlayController.show();
    final target =
        _highlightIndex >= 0 ? _highlightIndex : _nearestSlotIndex(slots);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo((target * _rowHeight)
          .clamp(0.0, _scrollController.position.maxScrollExtent));
    });
  }

  int _nearestSlotIndex(List<TimeOfDay> slots) {
    final target = widget.time.hour * 60 + widget.time.minute;
    var best = 0;
    var bestDiff = 24 * 60;
    for (var i = 0; i < slots.length; i++) {
      final slot = slots[i];
      final diff = (slot.hour * 60 + slot.minute - target).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  }

  void _closeDropdown() {
    if (_overlayController.isShowing) _overlayController.hide();
  }

  void _onTextChanged(String text) {
    final query = text.trim().toLowerCase();
    setState(() {
      _filteredSlots = query.isEmpty
          ? _daySlots
          : _daySlots
              .where((s) => formatTimeOfDay(s).toLowerCase().startsWith(query))
              .toList();
      _highlightIndex = _filteredSlots.isEmpty ? -1 : 0;
    });
    if (_filteredSlots.isEmpty) {
      _closeDropdown();
    } else if (!_overlayController.isShowing) {
      _overlayController.show();
    }
  }

  void _selectSlot(TimeOfDay t) {
    _controller.text = formatTimeOfDay(t);
    if (t != widget.time) widget.onChanged(t);
    _closeDropdown();
  }

  void _commit() {
    final parsed = parseTimeOfDay(_controller.text, widget.time);
    if (parsed == null) {
      _controller.text = formatTimeOfDay(widget.time);
      return;
    }
    _controller.text = formatTimeOfDay(parsed);
    if (parsed != widget.time) widget.onChanged(parsed);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_filteredSlots.isEmpty) return KeyEventResult.ignored;
      setState(() => _highlightIndex =
          (_highlightIndex + 1).clamp(0, _filteredSlots.length - 1));
      _controller.text = formatTimeOfDay(_filteredSlots[_highlightIndex]);
      if (!_overlayController.isShowing) _overlayController.show();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_filteredSlots.isEmpty) return KeyEventResult.ignored;
      setState(() => _highlightIndex =
          (_highlightIndex - 1).clamp(0, _filteredSlots.length - 1));
      _controller.text = formatTimeOfDay(_filteredSlots[_highlightIndex]);
      if (!_overlayController.isShowing) _overlayController.show();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _controller.text = formatTimeOfDay(widget.time);
      _closeDropdown();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (_highlightIndex >= 0 && _highlightIndex < _filteredSlots.length) {
        _selectSlot(_filteredSlots[_highlightIndex]);
      } else {
        _commit();
        _closeDropdown();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Focus(
      onKeyEvent: _onKeyEvent,
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
              child: _TimeSlotDropdown(
                slots: _filteredSlots,
                highlightIndex: _highlightIndex,
                scrollController: _scrollController,
                rowHeight: _rowHeight,
                onSelect: _selectSlot,
              ),
            ),
          ),
        ),
        child: CompositedTransformTarget(
          link: _layerLink,
          child: SizedBox(
            width: 92,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: c.separator,
                borderRadius: BorderRadius.circular(4),
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                onChanged: _onTextChanged,
                style: TextStyle(color: c.textPrimary, fontSize: 12),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                  isDense: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimeSlotDropdown extends StatelessWidget {
  const _TimeSlotDropdown({
    required this.slots,
    required this.highlightIndex,
    required this.scrollController,
    required this.rowHeight,
    required this.onSelect,
  });

  final List<TimeOfDay> slots;
  final int highlightIndex;
  final ScrollController scrollController;
  final double rowHeight;
  final ValueChanged<TimeOfDay> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.surfacePanel,
      elevation: 8,
      borderRadius: BorderRadius.circular(6),
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(minWidth: 92, maxWidth: 92, maxHeight: 240),
        child: ListView.builder(
          controller: scrollController,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: slots.length,
          itemExtent: rowHeight,
          itemBuilder: (ctx, i) {
            final selected = i == highlightIndex;
            return InkWell(
              onTap: () => onSelect(slots[i]),
              child: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                color: selected
                    ? AppColors.accent.withAlpha(40)
                    : Colors.transparent,
                child: Text(
                  formatTimeOfDay(slots[i]),
                  style: TextStyle(color: c.textPrimary, fontSize: 12),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
