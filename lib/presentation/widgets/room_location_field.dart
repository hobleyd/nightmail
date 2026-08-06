import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html_view/html_view.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/attendee_availability.dart';
import '../../domain/entities/meeting_room.dart';
import 'availability_status_style.dart';

/// The event form's Location field: booked rooms as chips, free text beside
/// them, and a dropdown of the account's rooms with a free/busy dot each.
///
/// The dropdown never hits the network. The room directory is fetched once per
/// account and handed in whole via [rooms] (the repository caches it for the
/// process' lifetime), and this widget only ever filters that list in memory —
/// the same rule the recipient typeahead follows, for the same reason.
///
/// Free/busy is the exception, because it depends on the slot rather than the
/// room: [availability] is supplied by the parent, which re-queries when the
/// meeting time or the visible room set changes. [onVisibleRoomsChanged] is how
/// this widget tells it which rooms are worth asking about — a tenant with three
/// hundred rooms must not turn one keystroke into three hundred lookups.
class RoomLocationField extends StatefulWidget {
  const RoomLocationField({
    super.key,
    required this.locationController,
    required this.selectedRooms,
    required this.onSelectedRoomsChanged,
    this.rooms = const [],
    this.loadingRooms = false,
    this.availability = const {},
    this.checkingAvailability = false,
    this.onVisibleRoomsChanged,
    this.readOnly = false,
    this.trailing,
  });

  /// Free-text part of the location — an address, a phone bridge, "Level 3
  /// kitchen". Rooms are *not* in here; they are [selectedRooms].
  final TextEditingController locationController;

  /// Rooms this meeting books. Order is preserved so the first one stays the
  /// meeting's primary location.
  final List<MeetingRoom> selectedRooms;
  final ValueChanged<List<MeetingRoom>> onSelectedRoomsChanged;

  /// Every room the account can offer. Empty is a legitimate state — an IMAP
  /// account, or a Google user with neither admin rights nor any subscribed room
  /// calendar — and the field then behaves as a plain text box.
  final List<MeetingRoom> rooms;
  final bool loadingRooms;

  /// Free/busy per room address, lower-cased. A missing entry means "not asked
  /// yet", which is drawn as no dot rather than as a grey one — an absent answer
  /// and an unknowable one look different on purpose.
  final Map<String, AttendeeAvailabilityStatus> availability;
  final bool checkingAvailability;

  /// The rooms currently on screen, in display order, whenever that set changes.
  final ValueChanged<List<MeetingRoom>>? onVisibleRoomsChanged;

  final bool readOnly;

  /// Rendered after the input — the Teams / Google Meet toggle.
  final Widget? trailing;

  @override
  State<RoomLocationField> createState() => _RoomLocationFieldState();
}

class _RoomLocationFieldState extends State<RoomLocationField> {
  /// Rooms shown at once. Past this the list stops being a picker and starts
  /// being a directory dump, and every extra row is another free/busy lookup.
  static const _maxVisibleRooms = 12;

  final _inputFocus = FocusNode();
  final _layerLink = LayerLink();
  final _overlayController = OverlayPortalController();

  List<MeetingRoom> _matches = const [];
  int _highlightedIndex = -1;
  bool _suppressNextFocusLoss = false;

  /// True while the dropdown is open because the user asked to browse rather
  /// than because they typed. It decides two things: the list ignores the
  /// field's text, and picking a room leaves that text alone — in browse mode
  /// the text is the user's location, not a search query to be consumed.
  bool _browsing = false;

  /// The field's text as of the last notification. A [TextEditingController]
  /// notifies on *selection* changes too, so focusing the field or moving the
  /// caret fires the same listener as typing — and without this, tapping the
  /// browse button (which focuses the field) was immediately treated as a
  /// keystroke, which cancelled the browse and re-filtered by the existing text.
  late String _lastText;

  /// The exact text the visible matches were found with — the whole field, or
  /// just its last word when that was the fallback. Selecting a room removes
  /// only this much, so a location typed beside the search survives.
  String? _queryUsed;

  /// Whether this field holds [HtmlViewOverlayGuard]. The dropdown is an
  /// [OverlayPortal], not a [ModalRoute], so nothing else tells a native
  /// WebView2 to get out of the way — and on Windows that HWND always paints
  /// over Flutter, swallowing the list. Same guard the recipient dropdown takes.
  bool _guardAcquired = false;

  @override
  void initState() {
    super.initState();
    _lastText = widget.locationController.text;
    widget.locationController.addListener(_onTextChanged);
    _inputFocus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(RoomLocationField old) {
    super.didUpdateWidget(old);
    if (old.locationController != widget.locationController) {
      old.locationController.removeListener(_onTextChanged);
      widget.locationController.addListener(_onTextChanged);
      // Re-baseline, or the new controller's text reads as a keystroke.
      _lastText = widget.locationController.text;
    }
    // The directory can arrive after the dropdown is already open, and a room
    // taken or released changes what is left to offer.
    if (_overlayController.isShowing &&
        (old.rooms != widget.rooms ||
            old.selectedRooms != widget.selectedRooms)) {
      _refreshMatches();
    }
  }

  @override
  void dispose() {
    widget.locationController.removeListener(_onTextChanged);
    _releaseGuard();
    _inputFocus.removeListener(_onFocusChanged);
    _inputFocus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_inputFocus.hasFocus) return;
    if (_suppressNextFocusLoss) {
      _suppressNextFocusLoss = false;
      return;
    }
    _closeDropdown();
  }

  void _onTextChanged() {
    if (!mounted || widget.readOnly) return;
    // Selection-only notifications are not typing; see [_lastText].
    if (widget.locationController.text == _lastText) return;
    _lastText = widget.locationController.text;
    // Typing filters the rooms, but only while the field has focus — the
    // controller also changes when the Teams button drops a placeholder in, and
    // that must not pop a dropdown open behind the user.
    if (!_inputFocus.hasFocus) return;
    // Typing is a search, not a browse — from here the text is the query again.
    _browsing = false;
    if (widget.locationController.text.trim().isEmpty) {
      _closeDropdown();
      return;
    }
    _refreshMatches();
  }

  /// Rooms matching the typed text, best match first.
  ///
  /// Ranked the same way as the recipient typeahead: a name that starts with the
  /// query beats one where a *word* starts with it, which beats a mid-string hit.
  /// Building and floor are searched too, so "level 3" and "SYD" find rooms.
  List<MeetingRoom> _filtered(String query) {
    final taken =
        widget.selectedRooms.map((r) => r.email.toLowerCase()).toSet();
    final available =
        widget.rooms.where((r) => !taken.contains(r.email.toLowerCase()));

    final q = query.trim().toLowerCase();
    if (q.isEmpty) return available.take(_maxVisibleRooms).toList();

    final scored = <(int, MeetingRoom)>[];
    for (final room in available) {
      final name = room.displayName.toLowerCase();
      final haystack = [
        name,
        room.email.toLowerCase(),
        room.building?.toLowerCase() ?? '',
        room.floorLabel == null ? '' : 'level ${room.floorLabel!.toLowerCase()}',
      ].join(' ');

      final int rank;
      if (name.startsWith(q)) {
        rank = 0;
      } else if (RegExp(r'\b' + RegExp.escape(q)).hasMatch(name)) {
        rank = 1;
      } else if (haystack.contains(q)) {
        rank = 2;
      } else {
        continue;
      }
      scored.add((rank, room));
    }

    scored.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);
      return byRank != 0
          ? byRank
          : a.$2.displayName.compareTo(b.$2.displayName);
    });
    return scored.map((e) => e.$2).take(_maxVisibleRooms).toList();
  }

  static bool _sameRooms(List<MeetingRoom> a, List<MeetingRoom> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].email != b[i].email) return false;
    }
    return true;
  }

  void _refreshMatches() {
    // Browsing lists the whole directory. Filtering it by whatever is already in
    // the field is what made the button useless on an existing meeting, whose
    // Location arrives with the provider's text in it.
    final query = _browsing ? '' : widget.locationController.text;
    var matches = _filtered(query);
    _queryUsed = _browsing ? null : query.trim();

    // Existing free text would otherwise poison the search: an open meeting
    // arrives with "Level 3" in the field, so typing a room name asks about
    // "Level 3 boardroom" and finds nothing. Retry on the last word when the
    // whole field matched nothing — tried second, so a multi-word room name
    // ("Huddle Space") still wins on the full text.
    if (matches.isEmpty && !_browsing) {
      final trimmed = query.trim();
      final lastWord = trimmed.split(RegExp(r'\s+')).last;
      if (lastWord.length >= 2 && lastWord != trimmed) {
        matches = _filtered(lastWord);
        if (matches.isNotEmpty) _queryUsed = lastWord;
      }
    }

    final changed = !_sameRooms(matches, _matches);

    setState(() {
      _matches = matches;
      _highlightedIndex = -1;
    });

    if (matches.isEmpty) {
      _releaseGuard();
      if (_overlayController.isShowing) _overlayController.hide();
      return;
    }

    _acquireGuard();
    if (!_overlayController.isShowing) _overlayController.show();

    // Ask for free/busy only for what is actually on screen. Reported after the
    // frame so the parent's setState does not land inside this build.
    if (changed && widget.onVisibleRoomsChanged != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onVisibleRoomsChanged!(matches);
      });
    }
  }

  /// Opens the dropdown on the whole room list, for someone who wants to browse
  /// rather than know what they are looking for — and the only way to add a room
  /// to a meeting that already has a location typed in.
  ///
  /// The refresh is deferred to after the frame, which the typing path does not
  /// need to do. [OverlayPortalController.show] flips `isShowing` immediately but
  /// only materialises the overlay child when the portal's own subtree is rebuilt
  /// in the same frame. Typing gets that for free — the controller notifies the
  /// TextField — but a button press does not, so showing from inside the tap
  /// handler leaves `isShowing` true with nothing on screen.
  void _openBrowse() {
    if (widget.readOnly) return;
    _browsing = true;
    _inputFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _browsing) _refreshMatches();
    });
  }

  void _closeDropdown() {
    _releaseGuard();
    _browsing = false;
    if (_overlayController.isShowing) _overlayController.hide();
    if (_matches.isEmpty && _highlightedIndex < 0) return;
    setState(() {
      _matches = const [];
      _highlightedIndex = -1;
    });
  }

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

  void _selectRoom(MeetingRoom room) {
    // Take the search text out, but only the search text: the chip now says what
    // it found, so leaving the query behind would double the room up in the saved
    // location — while a location typed beside it ("Level 3") must survive.
    // Browsing consumes nothing, because then the text was never a query.
    final consumed = _browsing ? null : _queryUsed;
    widget.onSelectedRoomsChanged([...widget.selectedRooms, room]);
    if (consumed != null && consumed.isNotEmpty) _consumeQueryText(consumed);
    _closeDropdown();
    _inputFocus.requestFocus();
  }

  /// Removes [query] from the end of the field, along with any separator left
  /// dangling in front of it. Leaves the field untouched if the text has moved on
  /// — better a stray word than a deleted location.
  void _consumeQueryText(String query) {
    final text = widget.locationController.text;
    if (text.trim() == query) {
      widget.locationController.clear();
      _lastText = '';
      return;
    }
    final end = text.trimRight();
    if (!end.toLowerCase().endsWith(query.toLowerCase())) return;
    final kept = end
        .substring(0, end.length - query.length)
        .replaceFirst(RegExp(r'[\s,;]+$'), '');
    widget.locationController.text = kept;
    _lastText = kept;
  }

  void _removeRoom(MeetingRoom room) {
    widget.onSelectedRoomsChanged(
      widget.selectedRooms.where((r) => r.email != room.email).toList(),
    );
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (_matches.isNotEmpty) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() => _highlightedIndex =
            (_highlightedIndex + 1).clamp(0, _matches.length - 1));
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() => _highlightedIndex =
            (_highlightedIndex - 1).clamp(-1, _matches.length - 1));
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _closeDropdown();
        return KeyEventResult.handled;
      }
      // Enter only commits a room that was deliberately highlighted. Otherwise
      // it falls through, so typing a location that happens to resemble a room
      // name and pressing Enter does not silently book that room.
      if (event.logicalKey == LogicalKeyboardKey.enter &&
          _highlightedIndex >= 0) {
        _selectRoom(_matches[_highlightedIndex]);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.tab) {
        _selectRoom(_matches[_highlightedIndex >= 0 ? _highlightedIndex : 0]);
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        widget.locationController.text.isEmpty &&
        widget.selectedRooms.isNotEmpty) {
      _removeRoom(widget.selectedRooms.last);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  AttendeeAvailabilityStatus? _statusFor(MeetingRoom room) =>
      widget.availability[room.email.toLowerCase()];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasRooms = widget.rooms.isNotEmpty || widget.loadingRooms;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final room in widget.selectedRooms)
                _RoomChip(
                  room: room,
                  status: _statusFor(room),
                  onRemove: widget.readOnly ? null : () => _removeRoom(room),
                ),
              IntrinsicWidth(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 120),
                  child: Focus(
                    onKeyEvent: (_, event) => _onKey(event),
                    child: OverlayPortal(
                      controller: _overlayController,
                      overlayChildBuilder: (_) => Align(
                        alignment: Alignment.topLeft,
                        child: CompositedTransformFollower(
                          link: _layerLink,
                          showWhenUnlinked: false,
                          targetAnchor: Alignment.bottomLeft,
                          followerAnchor: Alignment.topLeft,
                          child: Listener(
                            onPointerDown: (_) =>
                                _suppressNextFocusLoss = true,
                            child: _RoomDropdown(
                              rooms: _matches,
                              highlightedIndex: _highlightedIndex,
                              availability: widget.availability,
                              checkingAvailability:
                                  widget.checkingAvailability,
                              onSelect: _selectRoom,
                            ),
                          ),
                        ),
                      ),
                      child: CompositedTransformTarget(
                        link: _layerLink,
                        child: TextField(
                          controller: widget.locationController,
                          focusNode: _inputFocus,
                          readOnly: widget.readOnly,
                          style: TextStyle(
                              color: c.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: widget.selectedRooms.isNotEmpty
                                ? null
                                : hasRooms
                                    ? 'Add location or search rooms'
                                    : 'Add location',
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
              ),
            ],
          ),
        ),
        if (!widget.readOnly && hasRooms) ...[
          const SizedBox(width: 6),
          _BrowseRoomsButton(
            loading: widget.loadingRooms,
            onTap: widget.loadingRooms ? null : _openBrowse,
          ),
        ],
        if (widget.trailing != null) ...[
          const SizedBox(width: 8),
          widget.trailing!,
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Chip for a booked room
// ---------------------------------------------------------------------------

class _RoomChip extends StatelessWidget {
  const _RoomChip({required this.room, this.status, this.onRemove});

  final MeetingRoom room;
  final AttendeeAvailabilityStatus? status;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = status;
    // A booked room that reads as busy for its own meeting is the normal case
    // when editing — the parent discounts this meeting before handing the status
    // over, so a red dot here really does mean a clash with something else.
    final tooltip = [
      room.displayName,
      if (room.detailLine != null) room.detailLine!,
      if (s != null && (roomAvailabilityLabels[s] ?? '').isNotEmpty)
        roomAvailabilityLabels[s]!,
    ].join('\n');

    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.only(left: 7, right: 3, top: 3, bottom: 3),
        decoration: BoxDecoration(
          color: c.separator,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.separatorStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.meeting_room_outlined, size: 12, color: c.textSecondary),
            const SizedBox(width: 4),
            if (s != null) ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: availabilityStatusColor(s),
                ),
              ),
              const SizedBox(width: 4),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                room.displayName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.textSecondary, fontSize: 12),
              ),
            ),
            if (onRemove != null)
              GestureDetector(
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Icon(Icons.close, size: 12, color: c.textMuted),
                ),
              )
            else
              const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Room dropdown
// ---------------------------------------------------------------------------

class _RoomDropdown extends StatelessWidget {
  const _RoomDropdown({
    required this.rooms,
    required this.highlightedIndex,
    required this.availability,
    required this.checkingAvailability,
    required this.onSelect,
  });

  final List<MeetingRoom> rooms;
  final int highlightedIndex;
  final Map<String, AttendeeAvailabilityStatus> availability;
  final bool checkingAvailability;
  final ValueChanged<MeetingRoom> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.surfacePanel,
      elevation: 8,
      borderRadius: BorderRadius.circular(6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 300),
        child: ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: rooms.length,
          separatorBuilder: (_, _) => Divider(height: 1, color: c.border),
          itemBuilder: (_, i) {
            final room = rooms[i];
            final status = availability[room.email.toLowerCase()];
            final label =
                status == null ? null : roomAvailabilityLabels[status];

            return ListTile(
              dense: true,
              selected: i == highlightedIndex,
              selectedTileColor: AppColors.accent.withAlpha(40),
              hoverColor: AppColors.accent.withAlpha(20),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              visualDensity: VisualDensity.compact,
              leading: _RoomStatusDot(
                status: status,
                pending: checkingAvailability && status == null,
              ),
              minLeadingWidth: 10,
              horizontalTitleGap: 8,
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      room.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (label != null && label.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: TextStyle(
                        color: availabilityStatusColor(status!),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
              subtitle: room.detailLine == null
                  ? null
                  : Text(
                      room.detailLine!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
              onTap: () => onSelect(room),
            );
          },
        ),
      ),
    );
  }
}

/// The free/busy dot, or a placeholder while the lookup is in flight. Never a
/// grey "unknown" dot for a room we simply have not asked about yet — an
/// unanswered room and an unanswerable one are different things.
class _RoomStatusDot extends StatelessWidget {
  const _RoomStatusDot({required this.status, required this.pending});

  final AttendeeAvailabilityStatus? status;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (status == null) {
      return SizedBox(
        width: 8,
        height: 8,
        child: pending
            ? CircularProgressIndicator(strokeWidth: 1.2, color: c.textMuted)
            : null,
      );
    }
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: availabilityStatusColor(status!),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Browse button
// ---------------------------------------------------------------------------

class _BrowseRoomsButton extends StatelessWidget {
  const _BrowseRoomsButton({required this.loading, this.onTap});

  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: loading ? 'Loading rooms…' : 'Browse rooms',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: c.separator,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: c.separatorStrong),
          ),
          child: loading
              ? SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: c.textMuted),
                )
              : Icon(Icons.meeting_room_outlined,
                  size: 14, color: c.textSecondary),
        ),
      ),
    );
  }
}
