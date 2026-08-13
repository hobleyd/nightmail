import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';

import '../../core/platform/window_utils.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/online_meeting_url.dart';
import '../../core/utils/timezone_utils.dart';
import '../../domain/entities/attendee_availability.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/calendar_event_attendee.dart';
import '../../domain/entities/calendar_recurrence.dart';
import '../../domain/entities/meeting_notify_scope.dart';
import '../../domain/entities/meeting_room.dart';
import '../../domain/usecases/check_attendees_availability.dart';
import '../../domain/usecases/forward_calendar_event.dart';
import '../../domain/usecases/get_meeting_rooms.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../injection_container.dart';
import '../blocs/event_edit/event_edit_bloc.dart';
import '../blocs/event_edit/event_edit_event.dart';
import '../blocs/event_edit/event_edit_state.dart';
import 'availability_status_style.dart';
import 'date_time_fields.dart';
import 'forward_meeting_dialog.dart';
import 'recipient_input_field.dart';
import 'room_location_field.dart';

// ─── Public API ──────────────────────────────────────────────────────────────

class EventEditDialog extends StatelessWidget {
  const EventEditDialog({
    super.key,
    this.event,
    this.initialStart,
    this.accountId,
    this.isO365Account = false,
    this.isGmailAccount = false,
  });

  final CalendarEvent? event;
  final DateTime? initialStart;
  final String? accountId;
  final bool isO365Account;
  final bool isGmailAccount;

  static Future<void> show(
    BuildContext context, {
    CalendarEvent? event,
    DateTime? initialStart,
    String? accountId,
    bool isO365Account = false,
    bool isGmailAccount = false,
  }) async {
    await createSubWindow(
      WindowConfiguration(
        arguments: jsonEncode({
          'type': 'eventEdit',
          if (event != null) 'event': _eventToArgs(event),
          if (initialStart != null) 'initialStart': initialStart.toIso8601String(),
          if (accountId != null) 'accountId': accountId,
          if (isO365Account) 'isO365Account': true,
          if (isGmailAccount) 'isGmailAccount': true,
        }),
      ),
    );
  }

  static Map<String, dynamic> _eventToArgs(CalendarEvent e) => {
        'id': e.id,
        'subject': e.subject,
        'start': e.start.toUtc().toIso8601String(),
        'end': e.end.toUtc().toIso8601String(),
        'isAllDay': e.isAllDay,
        'isOrganizer': e.isOrganizer,
        if (e.location != null) 'location': e.location,
        if (e.onlineMeetingUrl != null)
          'onlineMeetingUrl': e.onlineMeetingUrl,
        if (e.bodyPreview != null) 'bodyPreview': e.bodyPreview,
        if (e.timezone != null) 'timezone': e.timezone,
        'attendees': e.attendees
            .map((a) => {
                  'email': a.email,
                  if (a.displayName != null) 'displayName': a.displayName,
                  'responseStatus': a.responseStatus.name,
                  // Without this the sub-window cannot tell a booked room from a
                  // guest, and reopening a meeting would move its rooms into the
                  // Guests field — and then re-invite them as people on save.
                  if (a.isResource) 'isResource': true,
                })
            .toList(),
        if (e.recurrence != null) 'recurrence': _recurrenceToArgs(e.recurrence!),
        if (e.reminderMinutes != null) 'reminderMinutes': e.reminderMinutes,
        // Preserved so the window can tell a single occurrence (recurrence
        // read-only, not sent) from a series master (recurrence editable).
        if (e.seriesMasterId != null) 'seriesMasterId': e.seriesMasterId,
      };

  static Map<String, dynamic> _recurrenceToArgs(CalendarRecurrence r) => {
        'frequency': r.frequency.name,
        'interval': r.interval,
        if (r.daysOfWeek != null) 'daysOfWeek': r.daysOfWeek,
        if (r.endDate != null) 'endDate': r.endDate!.toIso8601String(),
        if (r.count != null) 'count': r.count,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocListener<EventEditBloc, EventEditState>(
      listener: (context, state) {
        if (state is EventEditSaved) {
          Navigator.of(context).pop(true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  '${event == null ? 'Event created' : 'Event updated'}: ${state.event.subject}'),
              duration: const Duration(seconds: 2),
            ),
          );
        } else if (state is EventEditError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.message),
              backgroundColor: Colors.red.shade700,
            ),
          );
        }
      },
      child: Dialog(
        backgroundColor: c.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: SizedBox(
          width: kEventFormWidth,
          child: EventEditForm(
            event: event,
            initialStart: initialStart,
            accountId: accountId,
            onClose: () => Navigator.of(context).pop(false),
            checkAttendeesAvailability: sl<CheckAttendeesAvailability>(),
            getMeetingRooms: sl<GetMeetingRooms>(),
          ),
        ),
      ),
    );
  }
}

// ─── Form ─────────────────────────────────────────────────────────────────────

/// Reminder a newly created meeting starts with. Must be one of
/// [_ReminderDropdown._options], or the dropdown asserts on a missing value.
const int _kDefaultReminderMinutes = 15;

/// Natural width of the form column. The form does not grow with the window —
/// extra width goes to the schedule pane beside it.
const double kEventFormWidth = 560;

/// Width the schedule pane opens at, and the amount the host window grows by
/// when it is toggled on (see [EventEditForm.onSchedulePaneToggled]).
const double kSchedulePaneWidth = 280;

/// Floors for the two columns when the pane is open and the window is too
/// narrow to give both their natural width.
const double _kMinFormWidth = 320;
const double _kMinGridWidth = 200;

class EventEditForm extends StatefulWidget {
  const EventEditForm({
    super.key,
    this.event,
    this.initialStart,
    this.accountId,
    this.isO365Account = false,
    this.isGmailAccount = false,
    required this.onClose,
    this.onTitleChanged,
    this.checkAttendeesAvailability,
    this.getMeetingRooms,
    this.onSchedulePaneToggled,
  });
  final CalendarEvent? event;
  final DateTime? initialStart;
  final String? accountId;
  final bool isO365Account;
  final bool isGmailAccount;
  final VoidCallback onClose;
  final ValueChanged<String>? onTitleChanged;
  final CheckAttendeesAvailability? checkAttendeesAvailability;

  /// Null leaves the Location field as plain free text — which is what the
  /// account-less previews and tests want, and what an account with no room
  /// directory ends up with anyway.
  final GetMeetingRooms? getMeetingRooms;

  final void Function(bool expanded)? onSchedulePaneToggled;

  @override
  State<EventEditForm> createState() => _EventEditFormState();
}

class _EventEditFormState extends State<EventEditForm> {
  late final TextEditingController _titleController;
  late final TextEditingController _locationController;
  late final TextEditingController _descriptionController;

  late DateTime _startDate;
  late TimeOfDay _startTime;
  late DateTime _endDate;
  late TimeOfDay _endTime;
  late Duration _duration;
  late bool _isAllDay;
  late String _timezone;
  late List<String> _attendees;
  /// Response status of each guest the event was loaded with, keyed by
  /// lower-cased email. Drives the RSVP marker on each chip in the Guests
  /// field (see [_guestStatusBadge]); guests added in this session, and
  /// providers that don't report other people's responses, have no entry here.
  late final Map<String, AttendeeResponseStatus> _attendeeStatuses;
  late CalendarRecurrence? _recurrence;
  late int? _reminderMinutes;

  List<AttendeeAvailability>? _availabilities;
  bool _checkingAvailability = false;
  Timer? _availabilityDebounce;
  bool _isOnlineMeeting = false;
  bool _showSchedulePane = false;
  String? _organizerEmail;
  String? _hoveredLocationUrl;

  /// Rooms this meeting books. Separate from [_attendees] all the way to the
  /// provider: they are invited as resources, not people.
  late List<MeetingRoom> _selectedRooms;

  /// The account's room directory, and the rooms currently shown by the picker.
  List<MeetingRoom> _rooms = const [];
  bool _loadingRooms = false;
  List<MeetingRoom> _visibleRooms = const [];

  /// Free/busy per room address, lower-cased. Keyed by address rather than held
  /// as a list so a room's dot survives the picker's list changing under it, and
  /// so a room stays answered once asked about at this slot.
  final Map<String, AttendeeAvailabilityStatus> _roomAvailability = {};
  bool _checkingRoomAvailability = false;
  Timer? _roomAvailabilityDebounce;

  // Snapshot of the form's initial values, captured at the end of initState so
  // a save can tell what the organizer actually changed. Used to decide which
  // attendees to notify: any content change notifies everyone, an
  // attendee-list-only change notifies just the added/removed guests, and no
  // change notifies no one. Only meaningful when editing an existing event.
  late final String _initialSubject;
  late final String? _initialLocation;
  late final String? _initialDescription;
  late final DateTime _initialStartDate;
  late final TimeOfDay _initialStartTime;
  late final DateTime _initialEndDate;
  late final TimeOfDay _initialEndTime;
  late final bool _initialIsAllDay;
  late final String _initialTimezone;
  late final CalendarRecurrence? _initialRecurrence;
  late final bool _initialIsOnlineMeeting;
  late final Set<String> _initialAttendees;
  late final Set<String> _initialRooms;

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    final now = DateTime.now();
    // Next half-hour block, e.g. 2:12pm -> 2:30pm, 2:42pm -> 3:00pm.
    final nextHalfHour = now.minute < 30
        ? DateTime(now.year, now.month, now.day, now.hour, 30)
        : DateTime(now.year, now.month, now.day, now.hour + 1);

    _titleController = TextEditingController(text: e?.subject ?? '');

    // Rooms arrive back as resource attendees. Everything known about them at
    // this point is a name and an address; the room directory fills in capacity
    // and building once it loads (see [_loadRooms]).
    _selectedRooms = (e?.attendees ?? const <CalendarEventAttendee>[])
        .where((a) => a.isResource && a.email.isNotEmpty)
        .map((a) => MeetingRoom(
              email: a.email,
              displayName: a.displayName?.trim().isNotEmpty == true
                  ? a.displayName!
                  : a.email,
            ))
        .toList();

    // The provider's `location` names the booked rooms as well as any free text
    // (Graph mirrors locations[0] into it; Google has only the one string), so
    // the room names have to come back out or they would be shown twice — once
    // as a chip and once as typed-in text — and saved twice.
    _locationController = TextEditingController(
      text: _stripRoomNames(e?.location ?? '', _selectedRooms),
    );
    _descriptionController = TextEditingController(text: e?.bodyPreview ?? '');

    _titleController.addListener(_onTitleChanged);
    widget.onTitleChanged?.call(_windowTitle);

    final defaultStart = widget.initialStart ?? nextHalfHour;
    final defaultEnd = defaultStart.add(const Duration(minutes: 30));

    final startLocal = (e?.start ?? defaultStart).toLocal();
    final endLocal = (e?.end ?? defaultEnd).toLocal();

    _startDate = DateTime(startLocal.year, startLocal.month, startLocal.day);
    _startTime = TimeOfDay(hour: startLocal.hour, minute: startLocal.minute);
    _endDate = DateTime(endLocal.year, endLocal.month, endLocal.day);
    _endTime = TimeOfDay(hour: endLocal.hour, minute: endLocal.minute);
    _duration = endLocal.difference(startLocal);
    _isAllDay = e?.isAllDay ?? false;
    // The calendar list fetch forces timezone="UTC" via a Prefer header, so
    // treat null or "UTC" as unset and default to the device's local timezone.
    final storedTz = e?.timezone;
    _timezone = (storedTz == null || storedTz == 'UTC')
        ? _localIanaTimezone()
        : storedTz;
    _attendees = e?.attendees
            .where((a) => !a.isResource)
            .map((a) => a.email)
            .toList() ??
        const [];
    _attendeeStatuses = {
      for (final a in e?.attendees ?? const <CalendarEventAttendee>[])
        if (a.email.isNotEmpty) a.email.toLowerCase(): a.responseStatus,
    };
    // Reflects what the meeting actually is. It used to start false even for a
    // meeting that plainly had a Teams link, because the join URL was only ever
    // visible as the location text.
    _isOnlineMeeting = e?.hasOnlineMeeting ?? false;
    _recurrence = e?.recurrence;
    // A new meeting defaults to a 15-minute reminder; an existing one keeps
    // whatever the server has, including no reminder at all.
    _reminderMinutes = e == null ? _kDefaultReminderMinutes : e.reminderMinutes;
    // The account the meeting is being created on — not necessarily the active
    // one. This form runs in its own window (and so its own engine, which
    // restores whichever account was last persisted as active), so the id it
    // was opened with is the only reliable signal of whose calendar this is.
    final accounts = sl<AccountManager>();
    _organizerEmail =
        (accounts.accountById(widget.accountId) ?? accounts.activeAccount)
            ?.emailAddress;

    // Snapshot the initialized state, normalized the same way _submit() reads
    // it back, so change-detection compares like with like.
    _initialSubject = _titleController.text.trim();
    _initialLocation = _nullIfBlank(_locationController.text);
    _initialDescription = _nullIfBlank(_descriptionController.text);
    _initialStartDate = _startDate;
    _initialStartTime = _startTime;
    _initialEndDate = _endDate;
    _initialEndTime = _endTime;
    _initialIsAllDay = _isAllDay;
    _initialTimezone = _timezone;
    _initialRecurrence = _recurrence;
    _initialIsOnlineMeeting = _isOnlineMeeting;
    _initialAttendees = _attendees
        .map(_extractEmail)
        .map((a) => a.toLowerCase())
        .toSet();
    _initialRooms = _selectedRooms.map((r) => r.email.toLowerCase()).toSet();

    // An existing meeting opens with its guest list already filled in, so the
    // first free/busy fetch has to be kicked off here. Every other trigger is a
    // user edit, which means an organizer who opens a meeting and reads the
    // availability rows — or clicks "Find a time" — without touching anything
    // would otherwise see nothing at all.
    if (!_readOnly && !_isAllDay && _attendees.isNotEmpty) {
      _scheduleAvailabilityCheck();
    }

    if (!_readOnly) _loadRooms();
  }

  static String? _nullIfBlank(String s) {
    final t = s.trim();
    return t.isNotEmpty ? t : null;
  }

  /// Removes the booked rooms' names from a provider-supplied location string,
  /// leaving whatever free text was typed alongside them.
  ///
  /// Splits on the separators the two datasources join with (", " for Google's
  /// single string, "; " for a hand-typed list) and drops any segment that is a
  /// room's name or address. A segment that merely *contains* a room name is
  /// kept: "Meet outside Room 3" is free text, not a duplicated chip.
  static String _stripRoomNames(String location, List<MeetingRoom> rooms) {
    if (location.isEmpty || rooms.isEmpty) return location;
    final roomLabels = {
      for (final r in rooms) ...[
        r.displayName.trim().toLowerCase(),
        r.email.trim().toLowerCase(),
      ],
    };
    return location
        .split(RegExp(r'\s*[;,]\s*'))
        .where((segment) =>
            segment.trim().isNotEmpty &&
            !roomLabels.contains(segment.trim().toLowerCase()))
        .join(', ');
  }

  /// Fetches the account's room directory once, on open.
  ///
  /// The repository caches it for the process' lifetime, so this is a round-trip
  /// on the first event window of a session and free afterwards. A failure is
  /// deliberately silent: the Location field falls back to being a text box,
  /// which is exactly what it was before rooms existed.
  Future<void> _loadRooms() async {
    final loader = widget.getMeetingRooms;
    if (loader == null) return;

    setState(() => _loadingRooms = true);
    final result = await loader(accountId: widget.accountId);
    if (!mounted) return;

    final rooms = result.getRight().toNullable() ?? const <MeetingRoom>[];
    setState(() {
      _loadingRooms = false;
      _rooms = rooms;
      // Upgrade the chips built from bare resource attendees to the directory's
      // full records, so a reopened meeting shows its room's capacity and floor
      // rather than just the name it was saved with.
      final byEmail = {for (final r in rooms) r.email.toLowerCase(): r};
      _selectedRooms = _selectedRooms
          .map((r) => byEmail[r.email.toLowerCase()] ?? r)
          .toList();
    });

    // An already-booked room's status is worth showing straight away — it is how
    // the organizer sees that the room they had has been taken by someone else.
    if (_selectedRooms.isNotEmpty) _scheduleRoomAvailabilityCheck();
  }

  @override
  void dispose() {
    _roomAvailabilityDebounce?.cancel();
    _availabilityDebounce?.cancel();
    _titleController.removeListener(_onTitleChanged);
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  bool get _readOnly => widget.event != null && !widget.event!.isOrganizer;

  /// True when editing a single occurrence of a recurring series. The
  /// recurrence rule belongs to the series master, so here it's shown as a
  /// read-only note and never sent — changing how it repeats requires editing
  /// the whole series (chosen up front before the form opens).
  bool get _isSeriesOccurrence => widget.event?.isRecurringOccurrence ?? false;

  String get _baseTitle {
    if (widget.event == null) return 'New Event';
    return widget.event!.isOrganizer ? 'Edit Event' : 'View Event';
  }

  String get _windowTitle {
    final subject = _titleController.text.trim();
    return subject.isNotEmpty ? subject : _baseTitle;
  }

  void _onTitleChanged() {
    setState(() {});
    widget.onTitleChanged?.call(_windowTitle);
  }

  String _localIanaTimezone() => localIanaTimezone();

  DateTime get _computedStart => DateTime(
        _startDate.year, _startDate.month, _startDate.day,
        _startTime.hour, _startTime.minute,
      );

  DateTime get _computedEnd => DateTime(
        _endDate.year, _endDate.month, _endDate.day,
        _endTime.hour, _endTime.minute,
      );

  void _toggleSchedulePane() {
    final next = !_showSchedulePane;
    setState(() => _showSchedulePane = next);
    widget.onSchedulePaneToggled?.call(next);

    // Opening the pane is an explicit request to see schedules now, so don't
    // leave it behind the edit debounce. Covers a failed earlier fetch too,
    // which leaves _availabilities null — reopening retries rather than
    // showing an empty grid for good.
    if (next && _availabilities == null && !_checkingAvailability) {
      _availabilityDebounce?.cancel();
      _checkAvailability();
    }
  }

  void _onTimeSelected(DateTime newStart, DateTime newEnd) {
    setState(() {
      _startDate = DateTime(newStart.year, newStart.month, newStart.day);
      _startTime = TimeOfDay(hour: newStart.hour, minute: newStart.minute);
      _endDate = DateTime(newEnd.year, newEnd.month, newEnd.day);
      _endTime = TimeOfDay(hour: newEnd.hour, minute: newEnd.minute);
      _availabilities = null;
    });
    _onSlotEdited();
  }

  /// The meeting moved. Every free/busy answer — guests' and rooms' alike — was
  /// about the old slot, so both are dropped and re-asked.
  void _onSlotEdited() {
    setState(_roomAvailability.clear);
    _scheduleAvailabilityCheck();
    _scheduleRoomAvailabilityCheck();
  }

  void _scheduleAvailabilityCheck() {
    if (widget.checkAttendeesAvailability == null) return;
    _availabilityDebounce?.cancel();
    _availabilityDebounce = Timer(
      const Duration(milliseconds: 600),
      _checkAvailability,
    );
  }

  Future<void> _checkAvailability() async {
    final checker = widget.checkAttendeesAvailability;
    if (checker == null || _attendees.isEmpty || _isAllDay) {
      if (mounted) setState(() => _availabilities = null);
      return;
    }

    final start = _computedStart;
    final end = _computedEnd;
    if (!end.isAfter(start)) return;

    if (mounted) setState(() => _checkingAvailability = true);

    final attendeeEmails = _attendees.map(_extractEmail).toList();
    // A meeting must not be reported as a clash with itself. The exclusion uses
    // the event's *stored* slot rather than the form's current one: the guests'
    // copies stay where the server put them until this edit is saved, so after
    // dragging the meeting to a new time it is the old slot that has to be
    // discounted.
    final edited = widget.event;
    final result = await checker(CheckAttendeesAvailabilityParams(
      emails: attendeeEmails,
      start: start,
      end: end,
      organizerEmail: _organizerEmail,
      accountId: widget.accountId,
      excludeEventId: edited?.id,
      excludeStart: edited?.start,
      excludeEnd: edited?.end,
    ));

    if (!mounted) return;
    setState(() {
      _checkingAvailability = false;
      _availabilities = result.fold((_) => null, (a) => a);
    });
  }

  /// Re-asks for room free/busy, coalescing a burst of edits.
  ///
  /// Kept separate from [_scheduleAvailabilityCheck] because the two are driven
  /// by different things: guests change when the roster does, rooms change as the
  /// picker's filter moves. Sharing one debounce would let scrolling the room
  /// list keep re-querying every guest's calendar.
  void _scheduleRoomAvailabilityCheck() {
    if (widget.checkAttendeesAvailability == null) return;
    _roomAvailabilityDebounce?.cancel();
    _roomAvailabilityDebounce = Timer(
      const Duration(milliseconds: 350),
      _checkRoomAvailability,
    );
  }

  Future<void> _checkRoomAvailability() async {
    final checker = widget.checkAttendeesAvailability;
    if (checker == null || _isAllDay) return;

    // The rooms on screen plus the ones already booked — the booked ones are
    // shown as chips whether or not the dropdown is open.
    final wanted = <String, MeetingRoom>{
      for (final r in [..._selectedRooms, ..._visibleRooms])
        r.email.toLowerCase(): r,
    };
    // Only ask about rooms with no answer for this slot yet. The map is cleared
    // whenever the slot moves, so this is a per-slot memo rather than a stale one.
    final toQuery = wanted.keys
        .where((email) => !_roomAvailability.containsKey(email))
        .toList();
    if (toQuery.isEmpty) return;

    final start = _computedStart;
    final end = _computedEnd;
    if (!end.isAfter(start)) return;

    setState(() => _checkingRoomAvailability = true);

    final edited = widget.event;
    final result = await checker(CheckAttendeesAvailabilityParams(
      emails: toQuery,
      start: start,
      end: end,
      // Rooms only — no organizer. Passing one would make the repository fetch
      // the whole calendar for subjects, which is wasted work here: a room's
      // dot needs a status, not a list of what it is booked for.
      organizerEmail: null,
      accountId: widget.accountId,
      // A room already held by the meeting being edited must not be reported as
      // clashing with itself, exactly as for its guests.
      excludeEventId: edited?.id,
      excludeStart: edited?.start,
      excludeEnd: edited?.end,
    ));

    if (!mounted) return;
    setState(() {
      _checkingRoomAvailability = false;
      result.match((_) {}, (availabilities) {
        for (final a in availabilities) {
          _roomAvailability[a.email.toLowerCase()] = a.status;
        }
      });
    });
  }

  /// The location as one line, rooms first — what a read-only viewer sees, and
  /// the inverse of the [_stripRoomNames] the form did on load.
  String get _displayLocation => [
        ..._selectedRooms.map((r) => r.displayName),
        if (_locationController.text.trim().isNotEmpty)
          _locationController.text.trim(),
      ].join(', ');

  /// The picker telling us which rooms it is showing. Anything already answered
  /// for this slot costs nothing, so this only ever fetches the newcomers.
  void _onVisibleRoomsChanged(List<MeetingRoom> rooms) {
    _visibleRooms = rooms;
    _scheduleRoomAvailabilityCheck();
  }

  void _onSelectedRoomsChanged(List<MeetingRoom> rooms) {
    setState(() => _selectedRooms = rooms);
    _scheduleRoomAvailabilityCheck();
  }

  static final _emailInAngle = RegExp(r'<([^>]+)>');

  /// RSVP marker shown on a guest chip: tick for accepted, cross for declined,
  /// question mark for tentative. Returns null when there is nothing to report
  /// — the guest hasn't responded, was added in this session, or the provider
  /// won't disclose other people's responses (Exchange and Google both hide
  /// them from non-organizers, and CalDAV doesn't report them at all). So a
  /// bare chip means "no response known", not "no response given".
  Widget? _guestStatusBadge(String address) {
    final status = _attendeeStatuses[_extractEmail(address).toLowerCase()];
    final (icon, color, label) = switch (status) {
      AttendeeResponseStatus.accepted =>
        (Icons.check, const Color(0xFF34C759), 'Accepted'),
      AttendeeResponseStatus.declined =>
        (Icons.close, const Color(0xFFFF3B30), 'Declined'),
      AttendeeResponseStatus.tentative =>
        (Icons.question_mark, const Color(0xFFFF9F0A), 'Tentative'),
      AttendeeResponseStatus.none || null => (null, null, null),
    };
    if (icon == null) return null;
    return Tooltip(
      message: label!,
      child: Icon(icon, size: 12, color: color),
    );
  }

  static String _extractEmail(String address) {
    final m = _emailInAngle.firstMatch(address);
    return m != null ? m.group(1)! : address;
  }

  /// Forwards this meeting to somebody who was not invited.
  ///
  /// Reachable only from the read-only form, so [widget.event] is non-null and
  /// belongs to somebody else. Nothing on the form is saved or changed by it —
  /// it is an action about the meeting, not an edit to it, which is why it does
  /// not go through [EventEditBloc].
  Future<void> _forward() async {
    final event = widget.event;
    if (event == null) return;
    await ForwardMeetingDialog.show(
      context,
      meetingSubject: event.subject,
      meetingWhen: _formatEventWhen(event),
      send: ({required List<String> toAddresses, String? comment}) =>
          sl<ForwardCalendarEvent>()(
        ForwardCalendarEventParams(
          eventId: event.id,
          toAddresses: toAddresses,
          comment: comment,
        ),
      ),
    );
  }

  String _formatEventWhen(CalendarEvent event) {
    final start = event.start.toLocal();
    final date = DateFormat('EEE d MMM yyyy').format(start);
    if (event.isAllDay) return date;
    final from = DateFormat('h:mm a').format(start);
    final to = DateFormat('h:mm a').format(event.end.toLocal());
    return '$date  $from – $to';
  }

  void _submit() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a title')),
      );
      return;
    }

    final start = _isAllDay
        ? _startDate
        : DateTime(
            _startDate.year, _startDate.month, _startDate.day,
            _startTime.hour, _startTime.minute);
    final end = _isAllDay
        ? _endDate.add(const Duration(days: 1))
        : DateTime(
            _endDate.year, _endDate.month, _endDate.day,
            _endTime.hour, _endTime.minute);

    if (!end.isAfter(start)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must be after start time')),
      );
      return;
    }

    // Only the free text. The rooms travel as roomEmails and each datasource
    // names them in the provider's own location shape — Graph's structured
    // `locations` array, Google's single string.
    final location = _nullIfBlank(_locationController.text);
    final description = _nullIfBlank(_descriptionController.text);
    final attendeeEmails = _attendees.map(_extractEmail).toList();
    final roomEmails = _selectedRooms.map((r) => r.email).toList();

    context.read<EventEditBloc>().add(EventEditSubmitted(
          id: widget.event?.id,
          subject: title,
          start: start,
          end: end,
          isAllDay: _isAllDay,
          timezone: _timezone,
          location: location,
          description: description,
          attendeeEmails: attendeeEmails,
          roomEmails: roomEmails,
          // Only ever a request to *attach* one. Asking again for a meeting that
          // already has a link is not a no-op: Google answers a second
          // createRequest by minting a new conference, which would strand
          // everyone holding the old link.
          isOnlineMeeting: _isOnlineMeeting && !_initialIsOnlineMeeting,
          // Editing a single occurrence must not touch the series' recurrence.
          recurrence: _isSeriesOccurrence ? null : _recurrence,
          reminderMinutes: _reminderMinutes,
          notifyScope: _computeNotifyScope(
            subject: title,
            location: location,
            description: description,
            attendeeEmails: attendeeEmails,
          ),
        ));
  }

  /// Decides who to email about this save by diffing the form against its
  /// initial snapshot. Any change to meeting content notifies all attendees;
  /// a change confined to the attendee list notifies only the added/removed
  /// guests; no change notifies no one. Creates always notify all.
  MeetingNotifyScope _computeNotifyScope({
    required String subject,
    required String? location,
    required String? description,
    required List<String> attendeeEmails,
  }) {
    if (widget.event == null) return MeetingNotifyScope.all;

    // A room change is a change of *where the meeting is*, so it notifies
    // everyone — unlike a guest joining or leaving, which only concerns the
    // guests who moved. Both directions matter: a guest who walks to the old
    // room finds someone else's meeting in it.
    final roomsNow = _selectedRooms.map((r) => r.email.toLowerCase()).toSet();
    final roomsChanged = roomsNow.length != _initialRooms.length ||
        !roomsNow.containsAll(_initialRooms);

    final contentChanged = roomsChanged ||
        subject != _initialSubject ||
        location != _initialLocation ||
        description != _initialDescription ||
        _startDate != _initialStartDate ||
        _startTime != _initialStartTime ||
        _endDate != _initialEndDate ||
        _endTime != _initialEndTime ||
        _isAllDay != _initialIsAllDay ||
        _timezone != _initialTimezone ||
        _recurrence != _initialRecurrence ||
        _isOnlineMeeting != _initialIsOnlineMeeting;
    if (contentChanged) return MeetingNotifyScope.all;

    final now = attendeeEmails.map((a) => a.toLowerCase()).toSet();
    final rosterChanged = now.length != _initialAttendees.length ||
        !now.containsAll(_initialAttendees);
    return rosterChanged
        ? MeetingNotifyScope.changedAttendeesOnly
        : MeetingNotifyScope.none;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    final formColumn = Column(
      mainAxisSize: _showSchedulePane ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TitleBar(title: _windowTitle, onClose: widget.onClose),
        Divider(height: 1, color: c.border),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LabeledField(
                  label: 'Title',
                  child: TextField(
                    controller: _titleController,
                    autofocus: !_readOnly,
                    readOnly: _readOnly,
                    style: TextStyle(color: c.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Event title',
                      hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Divider(height: 1, color: c.separator),
                const SizedBox(height: 10),
                AbsorbPointer(
                  absorbing: _readOnly,
                  child: Row(
                    children: [
                      Expanded(
                        child: _DateTimeSection(
                          startDate: _startDate,
                          startTime: _startTime,
                          endDate: _endDate,
                          endTime: _endTime,
                          isAllDay: _isAllDay,
                          readOnly: _readOnly,
                          onStartDateChanged: (d) {
                            setState(() {
                              _startDate = d;
                              final newEnd = DateTime(d.year, d.month, d.day,
                                  _startTime.hour, _startTime.minute)
                                  .add(_duration);
                              _endDate = DateTime(newEnd.year, newEnd.month, newEnd.day);
                              _endTime = TimeOfDay(hour: newEnd.hour, minute: newEnd.minute);
                            });
                            _onSlotEdited();
                          },
                          onStartTimeChanged: (t) {
                            setState(() {
                              _startTime = t;
                              final newEnd = DateTime(_startDate.year,
                                  _startDate.month, _startDate.day,
                                  t.hour, t.minute)
                                  .add(_duration);
                              _endDate = DateTime(newEnd.year, newEnd.month, newEnd.day);
                              _endTime = TimeOfDay(hour: newEnd.hour, minute: newEnd.minute);
                            });
                            _onSlotEdited();
                          },
                          onEndDateChanged: (d) {
                            setState(() {
                              _endDate = d;
                              final newEnd = DateTime(d.year, d.month, d.day,
                                  _endTime.hour, _endTime.minute);
                              _duration = newEnd.difference(_computedStart);
                            });
                            _onSlotEdited();
                          },
                          onEndTimeChanged: (t) {
                            setState(() {
                              _endTime = t;
                              final newEnd = DateTime(_endDate.year,
                                  _endDate.month, _endDate.day, t.hour, t.minute);
                              _duration = newEnd.difference(_computedStart);
                            });
                            _onSlotEdited();
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      _AllDayToggle(
                        value: _isAllDay,
                        onChanged: (v) {
                          setState(() => _isAllDay = v);
                          // Switching to all-day removes the times the pane
                          // exists to negotiate, so collapse it (and shrink the
                          // window back) rather than leaving a stale grid open.
                          if (v && _showSchedulePane) _toggleSchedulePane();
                          _onSlotEdited();
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                AbsorbPointer(
                  absorbing: _readOnly,
                  child: _LabeledField(
                    label: 'Timezone',
                    child: _TimezoneSelector(
                      value: _timezone,
                      onChanged: (tz) => setState(() => _timezone = tz),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Divider(height: 1, color: c.separator),
                const SizedBox(height: 10),
                _LabeledField(
                  label: 'Location',
                  child: _readOnly
                      ? _LinkifiedText(
                          // The rooms were split out of the location text on
                          // load, so a viewer has to be shown them again — a
                          // guest reading an invitation needs to know which room
                          // to walk to.
                          text: _displayLocation,
                          style: TextStyle(color: c.textPrimary, fontSize: 13),
                          onHoverUrl: (u) =>
                              setState(() => _hoveredLocationUrl = u),
                        )
                      : RoomLocationField(
                          locationController: _locationController,
                          selectedRooms: _selectedRooms,
                          onSelectedRoomsChanged: _onSelectedRoomsChanged,
                          rooms: _rooms,
                          loadingRooms: _loadingRooms,
                          availability: _roomAvailability,
                          checkingAvailability: _checkingRoomAvailability,
                          onVisibleRoomsChanged: _onVisibleRoomsChanged,
                          trailing: (widget.isO365Account ||
                                  widget.isGmailAccount)
                              ? _OnlineMeetingButton(
                                  active: _isOnlineMeeting,
                                  locked: _initialIsOnlineMeeting,
                                  label:
                                      widget.isGmailAccount ? 'Meet' : 'Teams',
                                  onToggle: (v) {
                                    setState(() => _isOnlineMeeting = v);
                                    final placeholder = widget.isGmailAccount
                                        ? 'Google Meet'
                                        : 'Microsoft Teams Meeting';
                                    if (v &&
                                        _locationController.text
                                            .trim()
                                            .isEmpty) {
                                      _locationController.text = placeholder;
                                    } else if (!v &&
                                        _locationController.text.trim() ==
                                            placeholder) {
                                      _locationController.text = '';
                                    }
                                  },
                                )
                              : null,
                        ),
                ),
                // The join link used to be visible only because it *was* the
                // location text. Now that the two are separate fields it needs
                // somewhere of its own, or editing a meeting would hide the one
                // thing most attendees actually want from it.
                if (widget.event?.onlineMeetingUrl case final url?)
                  _JoinLinkRow(url: url),
                const SizedBox(height: 10),
                AbsorbPointer(
                  absorbing: _readOnly,
                  child: RecipientInputField(
                    label: 'Guests',
                    labelWidth: 68,
                    recipients: _attendees,
                    chipBadgeBuilder: _guestStatusBadge,
                    onChanged: (a) {
                      setState(() {
                        _attendees = a;
                        _availabilities = null;
                      });
                      _scheduleAvailabilityCheck();
                    },
                    hintText: 'Add guests by email',
                    accountId: widget.accountId,
                  ),
                ),
                // All-day events have no time to negotiate, so the availability
                // readout and the schedule pane are both meaningless for them.
                if (!_readOnly &&
                    !_isAllDay &&
                    widget.checkAttendeesAvailability != null)
                  _AvailabilitySection(
                    attendees: _attendees,
                    availabilities: _availabilities,
                    checking: _checkingAvailability,
                    onShowSchedule: _toggleSchedulePane,
                    scheduleShown: _showSchedulePane,
                    organizerEmail: _organizerEmail,
                  ),
                const SizedBox(height: 10),
                Divider(height: 1, color: c.separator),
                const SizedBox(height: 10),
                if (_isSeriesOccurrence)
                  _RecurringOccurrenceNote(recurrence: _recurrence)
                else
                  AbsorbPointer(
                    absorbing: _readOnly,
                    child: _RecurrenceSection(
                      recurrence: _recurrence,
                      startDate: _startDate,
                      onChanged: (r) => setState(() => _recurrence = r),
                    ),
                  ),
                const SizedBox(height: 10),
                Divider(height: 1, color: c.separator),
                const SizedBox(height: 10),
                AbsorbPointer(
                  absorbing: _readOnly,
                  child: _LabeledField(
                    label: 'Reminder',
                    child: _ReminderDropdown(
                      value: _reminderMinutes,
                      onChanged: (v) => setState(() => _reminderMinutes = v),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Divider(height: 1, color: c.separator),
                const SizedBox(height: 10),
                _LabeledField(
                  label: 'Notes',
                  child: _readOnly
                      ? _LinkifiedText(
                          text: _descriptionController.text,
                          style: TextStyle(color: c.textPrimary, fontSize: 13),
                        )
                      : TextField(
                          controller: _descriptionController,
                          maxLines: 4,
                          style: TextStyle(color: c.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Add notes',
                            hintStyle:
                                TextStyle(color: c.textMuted, fontSize: 13),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            isDense: true,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: c.border),
        _Footer(
          isEditing: widget.event != null,
          readOnly: _readOnly,
          onSave: _submit,
          onForward: _forward,
          onClose: widget.onClose,
          hoveredUrl: _hoveredLocationUrl,
        ),
      ],
    );

    if (_showSchedulePane) {
      final grid = _ScheduleGrid(
        attendees: [
          if (_organizerEmail != null &&
              !_attendees.map(_extractEmail).contains(_organizerEmail))
            _organizerEmail!,
          ..._attendees.map(_extractEmail),
        ],
        availabilities: _availabilities ?? [],
        meetingStart: _computedStart,
        meetingEnd: _computedEnd,
        organizerEmail: _organizerEmail,
        onClose: _toggleSchedulePane,
        onTimeSelected: _onTimeSelected,
      );

      // The form is a fixed-width column; every pixel the window gains goes to
      // the schedule grid, which lays its columns out from its own constraints.
      // Falls back to intrinsic sizes when the parent gives none — the in-app
      // dialog variant, where an Expanded/unbounded height would assert.
      return LayoutBuilder(
        builder: (context, constraints) {
          final bounded = constraints.hasBoundedWidth;
          // A window dragged narrower than form + grid squeezes the form
          // rather than pushing the grid off the edge.
          final formWidth = bounded
              ? math.max(_kMinFormWidth,
                  math.min(kEventFormWidth, constraints.maxWidth - _kMinGridWidth))
              : kEventFormWidth;
          final row = Row(
            mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: formWidth, child: formColumn),
              VerticalDivider(width: 1, thickness: 1, color: c.border),
              if (bounded)
                Expanded(child: grid)
              else
                SizedBox(width: kSchedulePaneWidth, child: grid),
            ],
          );
          return constraints.hasBoundedHeight
              ? row
              : SizedBox(height: 640, child: row);
        },
      );
    }

    return SizedBox(width: kEventFormWidth, child: formColumn);
  }
}

// ─── Recurring-occurrence note ─────────────────────────────────────────────────

/// Read-only line shown in place of the recurrence editor when editing a single
/// occurrence, explaining that the recurrence rule lives on the whole series.
class _RecurringOccurrenceNote extends StatelessWidget {
  const _RecurringOccurrenceNote({this.recurrence});

  final CalendarRecurrence? recurrence;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final r = recurrence;
    final cadence = r == null ? 'a recurring series' : _summarize(r);
    return Row(
      children: [
        Icon(Icons.repeat, size: 16, color: c.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Part of $cadence — editing this occurrence only.',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
        ),
      ],
    );
  }

  static String _summarize(CalendarRecurrence r) {
    final unit = switch (r.frequency) {
      RecurrenceFrequency.daily => r.interval > 1 ? 'days' : 'daily',
      RecurrenceFrequency.weekly => r.interval > 1 ? 'weeks' : 'weekly',
      RecurrenceFrequency.monthly => r.interval > 1 ? 'months' : 'monthly',
      RecurrenceFrequency.yearly => r.interval > 1 ? 'years' : 'yearly',
    };
    final base = r.interval > 1
        ? 'a series repeating every ${r.interval} $unit'
        : 'a $unit series';
    final days = r.daysOfWeek;
    if (r.frequency == RecurrenceFrequency.weekly &&
        days != null &&
        days.isNotEmpty) {
      const names = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final sorted = [...days]..sort();
      return '$base on ${sorted.map((d) => names[d]).join(', ')}';
    }
    return base;
  }
}

// ─── Date / time section ──────────────────────────────────────────────────────

class _DateTimeSection extends StatelessWidget {
  const _DateTimeSection({
    required this.startDate,
    required this.startTime,
    required this.endDate,
    required this.endTime,
    required this.isAllDay,
    required this.readOnly,
    required this.onStartDateChanged,
    required this.onStartTimeChanged,
    required this.onEndDateChanged,
    required this.onEndTimeChanged,
  });

  final DateTime startDate;
  final TimeOfDay startTime;
  final DateTime endDate;
  final TimeOfDay endTime;
  final bool isAllDay;
  final bool readOnly;
  final ValueChanged<DateTime> onStartDateChanged;
  final ValueChanged<TimeOfDay> onStartTimeChanged;
  final ValueChanged<DateTime> onEndDateChanged;
  final ValueChanged<TimeOfDay> onEndTimeChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 68,
              child: Text(
                'Start',
                style: TextStyle(
                    color: c.textDimmed,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
            ),
            DateFieldButton(
                date: startDate, onTap: () => _pickStartDate(context)),
            if (!isAllDay) ...[
              const SizedBox(width: 6),
              readOnly
                  ? TimeFieldButton(time: startTime, onTap: () {})
                  : TimeComboBox(
                      time: startTime, onChanged: onStartTimeChanged),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            SizedBox(
              width: 68,
              child: Text(
                'End',
                style: TextStyle(
                    color: c.textDimmed,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
            ),
            DateFieldButton(date: endDate, onTap: () => _pickEndDate(context)),
            if (!isAllDay) ...[
              const SizedBox(width: 6),
              readOnly
                  ? TimeFieldButton(time: endTime, onTap: () {})
                  : TimeComboBox(time: endTime, onChanged: onEndTimeChanged),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _pickStartDate(BuildContext context) async {
    final d = await showDatePicker(
      context: context,
      initialDate: startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) onStartDateChanged(d);
  }

  Future<void> _pickEndDate(BuildContext context) async {
    final d = await showDatePicker(
      context: context,
      initialDate: endDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) onEndDateChanged(d);
  }
}

class _AllDayToggle extends StatelessWidget {
  const _AllDayToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'All day',
          style: TextStyle(color: c.textDimmed, fontSize: 12),
        ),
        const SizedBox(width: 4),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: AppColors.accent,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}

// ─── Timezone selector ────────────────────────────────────────────────────────

// kTimezones and TzEntry are defined in core/utils/timezone_utils.dart

class _TimezoneSelector extends StatefulWidget {
  const _TimezoneSelector({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_TimezoneSelector> createState() => _TimezoneSelectorState();
}

class _TimezoneSelectorState extends State<_TimezoneSelector> {
  Future<void> _showPicker() async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _TimezonePickerDialog(current: widget.value),
    );
    if (result != null) widget.onChanged(result);
  }

  String get _label {
    final match = kTimezones.where((t) => t.iana == widget.value).firstOrNull;
    return match?.label ?? widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: _showPicker,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: c.separator,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_label, style: TextStyle(color: c.textPrimary, fontSize: 12)),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, size: 16, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

class _TimezonePickerDialog extends StatefulWidget {
  const _TimezonePickerDialog({required this.current});
  final String current;

  @override
  State<_TimezonePickerDialog> createState() => _TimezonePickerDialogState();
}

class _TimezonePickerDialogState extends State<_TimezonePickerDialog> {
  late List<TzEntry> _filtered;
  final _search = TextEditingController();
  final _scroll = ScrollController();

  static const _itemHeight = 56.0; // dense ListTile with subtitle

  @override
  void initState() {
    super.initState();
    _filtered = kTimezones;
    _search.addListener(_onSearch);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
  }

  void _scrollToSelected() {
    final idx = _filtered.indexWhere((t) => t.iana == widget.current);
    if (idx < 0 || !_scroll.hasClients) return;
    final maxExtent = _scroll.position.maxScrollExtent;
    final target = (idx * _itemHeight - _itemHeight * 2).clamp(0.0, maxExtent);
    _scroll.jumpTo(target);
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onSearch() {
    final q = _search.text.toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? kTimezones
          : kTimezones
              .where((t) =>
                  t.label.toLowerCase().contains(q) ||
                  t.iana.toLowerCase().contains(q))
              .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: SizedBox(
        width: 360,
        height: 480,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: TextField(
                controller: _search,
                autofocus: true,
                style: TextStyle(color: c.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search timezones…',
                  hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                  prefixIcon:
                      Icon(Icons.search, size: 18, color: c.textMuted),
                  filled: true,
                  fillColor: c.separator,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  isDense: true,
                ),
              ),
            ),
            Divider(height: 1, color: c.border),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                itemCount: _filtered.length,
                itemBuilder: (_, i) {
                  final tz = _filtered[i];
                  final isSelected = tz.iana == widget.current;
                  final offsetLabel = tz.offsetHours == 0
                      ? 'UTC'
                      : tz.offsetHours > 0
                          ? 'UTC+${tz.offsetHours}'
                          : 'UTC${tz.offsetHours}';
                  return ListTile(
                    dense: true,
                    selected: isSelected,
                    selectedColor: AppColors.accent,
                    selectedTileColor: AppColors.accent.withAlpha(20),
                    title: Text(
                      tz.label,
                      style: TextStyle(
                        color: isSelected ? AppColors.accent : c.textPrimary,
                        fontSize: 13,
                        fontWeight: isSelected ? FontWeight.w600 : null,
                      ),
                    ),
                    subtitle: Text(
                      tz.iana,
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
                    trailing: Text(
                      offsetLabel,
                      style: TextStyle(color: c.textMuted, fontSize: 12),
                    ),
                    onTap: () => Navigator.of(context).pop(tz.iana),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// ─── Recurrence section ───────────────────────────────────────────────────────

class _RecurrenceSection extends StatelessWidget {
  const _RecurrenceSection({
    required this.recurrence,
    required this.startDate,
    required this.onChanged,
  });

  final CalendarRecurrence? recurrence;
  final DateTime startDate;
  final ValueChanged<CalendarRecurrence?> onChanged;

  static const List<int> _weekdayDefaults = [1, 2, 3, 4, 5];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final showDayPicker = recurrence?.frequency == RecurrenceFrequency.weekly ||
        recurrence?.frequency == RecurrenceFrequency.daily;
    // "Every N days" has no clean meaning once a daily recurrence is
    // restricted to specific weekdays (it's sent as a weekly rule instead),
    // so hide the interval control in that case.
    final isDailyRestricted = recurrence?.frequency == RecurrenceFrequency.daily &&
        (recurrence?.daysOfWeek?.length ?? 7) < 7;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 68,
              child: Text(
                'Repeat',
                style: TextStyle(
                    color: c.textDimmed,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
            ),
            _FrequencyDropdown(
              value: recurrence?.frequency,
              onChanged: (freq) {
                if (freq == null) {
                  onChanged(null);
                } else {
                  onChanged(CalendarRecurrence(
                    frequency: freq,
                    interval: recurrence?.interval ?? 1,
                    daysOfWeek: freq == RecurrenceFrequency.weekly
                        ? (recurrence?.daysOfWeek ?? [startDate.weekday])
                        : freq == RecurrenceFrequency.daily
                            ? (recurrence?.daysOfWeek ?? _weekdayDefaults)
                            : null,
                    endDate: recurrence?.endDate,
                    count: recurrence?.count,
                  ));
                }
              },
            ),
            if (recurrence != null && !isDailyRestricted) ...[
              const SizedBox(width: 8),
              Text('every', style: TextStyle(color: c.textMuted, fontSize: 12)),
              const SizedBox(width: 6),
              _IntervalField(
                value: recurrence!.interval,
                onChanged: (v) => onChanged(CalendarRecurrence(
                  frequency: recurrence!.frequency,
                  interval: v,
                  daysOfWeek: recurrence!.daysOfWeek,
                  endDate: recurrence!.endDate,
                  count: recurrence!.count,
                )),
              ),
              const SizedBox(width: 4),
              Text(
                _intervalLabel(recurrence!.frequency, recurrence!.interval),
                style: TextStyle(color: c.textMuted, fontSize: 12),
              ),
            ],
          ],
        ),
        if (showDayPicker) ...[
          const SizedBox(height: 8),
          _DayOfWeekPicker(
            selected: recurrence!.daysOfWeek ??
                (recurrence!.frequency == RecurrenceFrequency.daily
                    ? _weekdayDefaults
                    : [startDate.weekday]),
            onChanged: (days) => onChanged(CalendarRecurrence(
              frequency: recurrence!.frequency,
              interval: recurrence!.interval,
              daysOfWeek: days,
              endDate: recurrence!.endDate,
              count: recurrence!.count,
            )),
          ),
        ],
        if (recurrence != null) ...[
          const SizedBox(height: 8),
          _EndConditionRow(
            recurrence: recurrence!,
            startDate: startDate,
            onChanged: onChanged,
          ),
        ],
      ],
    );
  }

  String _intervalLabel(RecurrenceFrequency freq, int interval) {
    return switch (freq) {
      RecurrenceFrequency.daily => interval == 1 ? 'day' : 'days',
      RecurrenceFrequency.weekly => interval == 1 ? 'week' : 'weeks',
      RecurrenceFrequency.monthly => interval == 1 ? 'month' : 'months',
      RecurrenceFrequency.yearly => interval == 1 ? 'year' : 'years',
    };
  }
}

class _FrequencyDropdown extends StatelessWidget {
  const _FrequencyDropdown({required this.value, required this.onChanged});
  final RecurrenceFrequency? value;
  final ValueChanged<RecurrenceFrequency?> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.separator,
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<RecurrenceFrequency?>(
          value: value,
          isDense: true,
          dropdownColor: c.surfacePanel,
          style: TextStyle(color: c.textPrimary, fontSize: 12),
          items: [
            DropdownMenuItem(
              value: null,
              child: Text('Does not repeat',
                  style: TextStyle(color: c.textPrimary, fontSize: 12)),
            ),
            ...RecurrenceFrequency.values.map(
              (f) => DropdownMenuItem(
                value: f,
                child: Text(_freqLabel(f),
                    style: TextStyle(color: c.textPrimary, fontSize: 12)),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  String _freqLabel(RecurrenceFrequency f) => switch (f) {
        RecurrenceFrequency.daily => 'Daily',
        RecurrenceFrequency.weekly => 'Weekly',
        RecurrenceFrequency.monthly => 'Monthly',
        RecurrenceFrequency.yearly => 'Yearly',
      };
}

class _IntervalField extends StatelessWidget {
  const _IntervalField({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 40,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.separator,
        borderRadius: BorderRadius.circular(4),
      ),
      child: TextField(
        controller: TextEditingController(text: '$value'),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.center,
        style: TextStyle(color: c.textPrimary, fontSize: 12),
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          isDense: true,
        ),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null && n >= 1) onChanged(n);
        },
      ),
    );
  }
}

class _DayOfWeekPicker extends StatelessWidget {
  const _DayOfWeekPicker({required this.selected, required this.onChanged});
  final List<int> selected;
  final ValueChanged<List<int>> onChanged;

  static const _labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        const SizedBox(width: 68),
        ...List.generate(7, (i) {
          final day = i + 1;
          final isOn = selected.contains(day);
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () {
                final next = List<int>.from(selected);
                if (isOn) {
                  if (next.length > 1) next.remove(day);
                } else {
                  next.add(day);
                  next.sort();
                }
                onChanged(next);
              },
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOn ? AppColors.accent : c.separator,
                  border: Border.all(
                    color: isOn ? AppColors.accent : c.separatorStrong,
                  ),
                ),
                child: Center(
                  child: Text(
                    _labels[i],
                    style: TextStyle(
                      color: isOn ? Colors.white : c.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _EndConditionRow extends StatelessWidget {
  const _EndConditionRow({
    required this.recurrence,
    required this.startDate,
    required this.onChanged,
  });

  final CalendarRecurrence recurrence;
  final DateTime startDate;
  final ValueChanged<CalendarRecurrence?> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final endType = recurrence.endDate != null
        ? 'date'
        : recurrence.count != null
            ? 'count'
            : 'never';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(width: 68),
        Text('Ends', style: TextStyle(color: c.textDimmed, fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(width: 8),
        _EndTypeDropdown(
          value: endType,
          onChanged: (type) {
            switch (type) {
              case 'never':
                onChanged(CalendarRecurrence(
                    frequency: recurrence.frequency,
                    interval: recurrence.interval,
                    daysOfWeek: recurrence.daysOfWeek));
              case 'date':
                onChanged(CalendarRecurrence(
                    frequency: recurrence.frequency,
                    interval: recurrence.interval,
                    daysOfWeek: recurrence.daysOfWeek,
                    endDate: startDate.add(const Duration(days: 90))));
              case 'count':
                onChanged(CalendarRecurrence(
                    frequency: recurrence.frequency,
                    interval: recurrence.interval,
                    daysOfWeek: recurrence.daysOfWeek,
                    count: 10));
            }
          },
        ),
        if (endType == 'date') ...[
          const SizedBox(width: 8),
          DateFieldButton(
            date: recurrence.endDate!,
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: recurrence.endDate!,
                firstDate: startDate,
                lastDate: DateTime(2100),
              );
              if (d != null) {
                onChanged(CalendarRecurrence(
                  frequency: recurrence.frequency,
                  interval: recurrence.interval,
                  daysOfWeek: recurrence.daysOfWeek,
                  endDate: d,
                ));
              }
            },
          ),
        ],
        if (endType == 'count') ...[
          const SizedBox(width: 8),
          _IntervalField(
            value: recurrence.count ?? 10,
            onChanged: (v) => onChanged(CalendarRecurrence(
              frequency: recurrence.frequency,
              interval: recurrence.interval,
              daysOfWeek: recurrence.daysOfWeek,
              count: v,
            )),
          ),
          const SizedBox(width: 4),
          Text('times', style: TextStyle(color: c.textMuted, fontSize: 12)),
        ],
      ],
    );
  }
}

class _EndTypeDropdown extends StatelessWidget {
  const _EndTypeDropdown({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.separator,
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          dropdownColor: c.surfacePanel,
          style: TextStyle(color: c.textPrimary, fontSize: 12),
          items: [
            DropdownMenuItem(
                value: 'never',
                child: Text('Never',
                    style: TextStyle(color: c.textPrimary, fontSize: 12))),
            DropdownMenuItem(
                value: 'date',
                child: Text('On date',
                    style: TextStyle(color: c.textPrimary, fontSize: 12))),
            DropdownMenuItem(
                value: 'count',
                child: Text('After',
                    style: TextStyle(color: c.textPrimary, fontSize: 12))),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

// ─── Attendee availability ────────────────────────────────────────────────────

class _AvailabilitySection extends StatelessWidget {
  const _AvailabilitySection({
    required this.attendees,
    required this.availabilities,
    required this.checking,
    this.onShowSchedule,
    this.scheduleShown = false,
    this.organizerEmail,
  });

  final List<String> attendees;
  final List<AttendeeAvailability>? availabilities;
  final bool checking;
  final VoidCallback? onShowSchedule;
  final bool scheduleShown;
  final String? organizerEmail;

  @override
  Widget build(BuildContext context) {
    if (attendees.isEmpty) return const SizedBox.shrink();

    final c = context.colors;

    // Rows are per-guest free/busy summaries. `unknown` guests are omitted
    // because there is nothing truthful to say about them — the provider either
    // does not expose free/busy (CalDAV) or would not disclose that mailbox.
    // The schedule pane is still offered in that case: an empty column is a
    // fair picture of "we cannot see this calendar", and the organizer's own
    // calendar is worth scanning regardless.
    final rows = (availabilities ?? const <AttendeeAvailability>[])
        .where((a) =>
            a.status != AttendeeAvailabilityStatus.unknown &&
            a.email != organizerEmail)
        .toList();

    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 68),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final a in rows)
            _AvailabilityRow(availability: a, onScheduleTap: onShowSchedule),
          Padding(
            padding: EdgeInsets.only(top: rows.isEmpty ? 0 : 4),
            child: Row(
              children: [
                if (onShowSchedule != null)
                  _FindTimeButton(
                    shown: scheduleShown,
                    onTap: onShowSchedule!,
                  ),
                if (checking) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: c.textMuted,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Checking availability…',
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens (or closes) the schedule pane. Always available once the meeting has
/// a guest — finding a free slot is exactly the case where nobody is busy yet,
/// so this must not be gated on a detected conflict.
class _FindTimeButton extends StatelessWidget {
  const _FindTimeButton({required this.shown, required this.onTap});

  final bool shown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              shown ? Icons.chevron_right_rounded : Icons.event_available_rounded,
              size: 13,
              color: AppColors.accent,
            ),
            const SizedBox(width: 3),
            Text(
              shown ? 'Hide schedules' : 'Find a time',
              style: const TextStyle(
                color: AppColors.accent,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvailabilityRow extends StatelessWidget {
  const _AvailabilityRow({required this.availability, this.onScheduleTap});
  final AttendeeAvailability availability;
  final VoidCallback? onScheduleTap;

  /// The status word doubles as a shortcut into the schedule pane. Free guests
  /// are included: the pane is how you pick a slot, so it has to be reachable
  /// when everyone is free — which is the normal case, not the exception.
  bool get _isTappable => onScheduleTap != null;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = availabilityStatusColor(availability.status);
    final label = availabilityStatusLabels[availability.status] ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              availability.email,
              style: TextStyle(color: c.textMuted, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          if (_isTappable)
            GestureDetector(
              onTap: onScheduleTap,
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: color,
                ),
              ),
            )
          else
            Text(
              label,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w500),
            ),
        ],
      ),
    );
  }
}

// ─── Schedule grid ────────────────────────────────────────────────────────────

class _ScheduleGrid extends StatefulWidget {
  const _ScheduleGrid({
    required this.attendees,
    required this.availabilities,
    required this.meetingStart,
    required this.meetingEnd,
    required this.onClose,
    required this.onTimeSelected,
    this.organizerEmail,
  });

  final List<String> attendees;
  final List<AttendeeAvailability> availabilities;
  final DateTime meetingStart; // local time
  final DateTime meetingEnd;   // local time
  final VoidCallback onClose;
  final void Function(DateTime start, DateTime end) onTimeSelected;
  final String? organizerEmail;

  @override
  State<_ScheduleGrid> createState() => _ScheduleGridState();
}

class _ScheduleGridState extends State<_ScheduleGrid> {
  final _scroll = ScrollController();

  static const _startHour = 7;
  static const _endHour = 20;
  static const _hourHeight = 60.0;
  static const _timeColWidth = 44.0;
  static const _headerHeight = 38.0;
  static const _titleHeight = 46.0;

  double get _totalHeight => (_endHour - _startHour) * _hourHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToMeeting());
  }

  @override
  void didUpdateWidget(_ScheduleGrid old) {
    super.didUpdateWidget(old);
    if (old.meetingStart != widget.meetingStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToMeeting());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToMeeting() {
    if (!_scroll.hasClients) return;
    final hour = widget.meetingStart.hour + widget.meetingStart.minute / 60.0;
    final offset = ((hour - _startHour - 1.5) * _hourHeight)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(offset,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  double _localTimeToY(int hour, int minute) {
    final hours = hour + minute / 60.0 - _startHour;
    return (hours * _hourHeight).clamp(0.0, _totalHeight);
  }

  void _onTapUp(TapUpDetails details, double colWidth) {
    final x = details.localPosition.dx;
    if (x < _timeColWidth) return;
    final y = details.localPosition.dy;
    final totalMinutes = (y / _hourHeight * 60 + _startHour * 60).round();
    final snapped = (totalMinutes ~/ 30) * 30;
    final hour = snapped ~/ 60;
    final minute = snapped % 60;
    if (hour < _startHour || hour >= _endHour) return;
    final date = widget.meetingStart;
    final newStart = DateTime(date.year, date.month, date.day, hour, minute);
    final duration = widget.meetingEnd.difference(widget.meetingStart);
    widget.onTimeSelected(newStart, newStart.add(duration));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dateLabel = DateFormat('EEE, MMM d').format(widget.meetingStart);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _titleHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  'Schedules — $dateLabel',
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  onPressed: widget.onClose,
                  icon: Icon(Icons.close_rounded, size: 16, color: c.textMuted),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: c.border),
        _buildAttendeeHeader(c),
        Divider(height: 1, color: c.separator),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gridWidth = constraints.maxWidth;
              final n = widget.attendees.length;
              final colWidth = n > 0
                  ? (gridWidth - _timeColWidth) / n
                  : gridWidth - _timeColWidth;

              return SingleChildScrollView(
                controller: _scroll,
                child: GestureDetector(
                  onTapUp: (d) => _onTapUp(d, colWidth),
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    height: _totalHeight,
                    width: gridWidth,
                    child: Stack(
                      children: [
                        ..._buildHourBands(c),
                        ..._buildGridLines(c),
                        ..._buildTimeLabels(c),
                        _buildMeetingHighlight(),
                        for (int i = 0; i < widget.attendees.length; i++)
                          ..._buildAttendeeBlocks(i, colWidth),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            'Tap to propose a new time',
            style: TextStyle(color: c.textDimmed, fontSize: 10),
          ),
        ),
      ],
    );
  }

  Widget _buildAttendeeHeader(AppColors c) {
    return SizedBox(
      height: _headerHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final n = widget.attendees.length;
          final colWidth = n > 0
              ? (constraints.maxWidth - _timeColWidth) / n
              : constraints.maxWidth - _timeColWidth;
          return Row(
            children: [
              SizedBox(width: _timeColWidth),
              for (final email in widget.attendees)
                SizedBox(
                  width: colWidth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 4),
                    child: Text(
                      email == widget.organizerEmail
                          ? 'Me'
                          : email.split('@').first,
                      style: TextStyle(
                        color: email == widget.organizerEmail
                            ? AppColors.accent
                            : c.textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildHourBands(AppColors c) {
    final total = _endHour - _startHour;
    return List.generate(
      total,
      (i) => Positioned(
        top: i * _hourHeight,
        left: 0,
        right: 0,
        height: _hourHeight,
        child: Container(
          color: i.isEven ? c.surfacePanel : c.separator.withAlpha(60),
        ),
      ),
    );
  }

  List<Widget> _buildGridLines(AppColors c) {
    final total = _endHour - _startHour + 1;
    return List.generate(
      total,
      (i) => Positioned(
        top: i * _hourHeight,
        left: _timeColWidth,
        right: 0,
        height: 1,
        child: Container(color: c.separator),
      ),
    );
  }

  List<Widget> _buildTimeLabels(AppColors c) {
    final total = _endHour - _startHour;
    return List.generate(total, (i) {
      final hour = _startHour + i;
      final label = hour == 12
          ? '12 PM'
          : hour < 12
              ? '$hour AM'
              : '${hour - 12} PM';
      return Positioned(
        top: i * _hourHeight + 3,
        left: 0,
        width: _timeColWidth - 4,
        child: Text(
          label,
          style: TextStyle(color: c.textDimmed, fontSize: 9),
          textAlign: TextAlign.right,
        ),
      );
    });
  }

  Widget _buildMeetingHighlight() {
    final startY = _localTimeToY(
        widget.meetingStart.hour, widget.meetingStart.minute);
    final endY =
        _localTimeToY(widget.meetingEnd.hour, widget.meetingEnd.minute);
    if (endY <= startY) return const SizedBox.shrink();
    return Positioned(
      left: _timeColWidth,
      top: startY,
      right: 0,
      height: endY - startY,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.accent.withAlpha(35),
          border: const Border(
              left: BorderSide(color: AppColors.accent, width: 2)),
        ),
      ),
    );
  }

  List<Widget> _buildAttendeeBlocks(int i, double colWidth) {
    final email = widget.attendees[i];
    // Case-insensitive: an existing meeting's guest list carries whatever
    // casing the server stored, which need not match how the provider echoes
    // the address back in its free/busy response.
    final avail = widget.availabilities.firstWhere(
      (a) => a.email.toLowerCase() == email.toLowerCase(),
      orElse: () => AttendeeAvailability(
          email: email, status: AttendeeAvailabilityStatus.unknown),
    );
    final left = _timeColWidth + i * colWidth;
    final dayStart = DateTime(widget.meetingStart.year,
        widget.meetingStart.month, widget.meetingStart.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    return avail.scheduleItems
        .where((item) {
          final localStart = item.start.toLocal();
          final localEnd = item.end.toLocal();
          return localStart.isBefore(dayEnd) && localEnd.isAfter(dayStart);
        })
        .map((item) {
          final localStart = item.start.toLocal();
          final localEnd = item.end.toLocal();
          final startY =
              _localTimeToY(localStart.hour, localStart.minute);
          final endY = _localTimeToY(localEnd.hour, localEnd.minute);
          if (endY <= startY) return null;

          final color = switch (item.status) {
            AttendeeAvailabilityStatus.busy =>
              const Color(0xFFFF3B30).withAlpha(140),
            AttendeeAvailabilityStatus.outOfOffice =>
              const Color(0xFFFF3B30).withAlpha(100),
            AttendeeAvailabilityStatus.tentative =>
              const Color(0xFFFF9F0A).withAlpha(130),
            AttendeeAvailabilityStatus.workingElsewhere =>
              const Color(0xFF5E5CE6).withAlpha(100),
            _ => null,
          };
          if (color == null) return null;

          final blockHeight = (endY - startY).clamp(1.0, double.infinity);
          final label = item.isPrivate
              ? 'Private'
              : (item.subject?.isNotEmpty == true ? item.subject! : null);

          return Positioned(
            left: left + 2,
            top: startY,
            width: colWidth - 4,
            height: blockHeight,
            child: ClipRect(
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
                padding: blockHeight >= 14
                    ? const EdgeInsets.only(left: 3, top: 1, right: 2)
                    : null,
                child: blockHeight >= 14 && label != null
                    ? Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w500,
                          height: 1.2,
                        ),
                        maxLines: (blockHeight / 11).floor().clamp(1, 3),
                        overflow: TextOverflow.ellipsis,
                      )
                    : null,
              ),
            ),
          );
        })
        .whereType<Widget>()
        .toList();
  }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

class _LinkifiedText extends StatefulWidget {
  const _LinkifiedText({required this.text, required this.style, this.onHoverUrl});
  final String text;
  final TextStyle style;
  /// Called with the real (unshortened) URL while the pointer hovers a link,
  /// and with `null` when it leaves.
  final ValueChanged<String?>? onHoverUrl;

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  static final _urlPattern = RegExp(r'https?://[^\s<>"{}|\\^`\[\]]+');

  /// Teams meetup-join URLs carry a long opaque meeting-id/context token
  /// that's meaningless to display; show a clean stand-in for the label
  /// while the tap recognizer still opens the real [url].
  static String _displayUrl(String url) {
    if (url.startsWith('https://teams.microsoft.com')) {
      return 'https://teams.microsoft.com/join-meeting';
    }
    return url;
  }

  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  List<InlineSpan> _buildSpans() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final text = widget.text;
    final spans = <InlineSpan>[];
    int last = 0;

    for (final match in _urlPattern.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(
          text: text.substring(last, match.start),
          style: widget.style,
        ));
      }
      final url = match.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => launchUrl(
              Uri.parse(url),
              mode: LaunchMode.externalApplication,
            );
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: _displayUrl(url),
        style: widget.style.copyWith(
          color: AppColors.accent,
          decoration: TextDecoration.underline,
          decorationColor: AppColors.accent,
        ),
        recognizer: recognizer,
        mouseCursor: SystemMouseCursors.click,
        onEnter: (_) => widget.onHoverUrl?.call(url),
        onExit: (_) => widget.onHoverUrl?.call(null),
      ));
      last = match.end;
    }

    if (last < text.length) {
      spans.add(TextSpan(
        text: text.substring(last),
        style: widget.style,
      ));
    }

    return spans;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.text.isEmpty) return const SizedBox.shrink();
    return SelectableText.rich(TextSpan(children: _buildSpans()));
  }
}

class _OnlineMeetingButton extends StatelessWidget {
  const _OnlineMeetingButton({
    required this.active,
    required this.onToggle,
    required this.label,
    this.locked = false,
  });
  final bool active;
  final ValueChanged<bool> onToggle;
  final String label;

  /// Set once the meeting already has an online meeting attached. Neither
  /// provider lets one be added or removed after the fact through this form —
  /// Google would answer a second `createRequest` by minting a *new* link, and
  /// Graph will not flip `isOnlineMeeting` on an existing event — so the toggle
  /// reports the state rather than pretending to change it.
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final button = GestureDetector(
      onTap: locked ? null : () => onToggle(!active),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? AppColors.accent : c.separator,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videocam_outlined,
              size: 13,
              color: active ? Colors.white : c.textMuted,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: active ? Colors.white : c.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );

    if (!locked) return button;
    return Tooltip(
      message: '$label meeting — the link cannot be added or removed here',
      child: button,
    );
  }
}

/// The meeting's join link, under the Location field.
///
/// Shows the platform's name rather than the URL: a Teams or Meet link is a long
/// opaque token that tells the reader nothing and would swamp the row.
class _JoinLinkRow extends StatelessWidget {
  const _JoinLinkRow({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 68),
      child: Row(
        children: [
          Icon(Icons.videocam_outlined, size: 13, color: c.textMuted),
          const SizedBox(width: 5),
          Text(
            onlineMeetingPlatformName(url),
            style: TextStyle(color: c.textMuted, fontSize: 11),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: url,
            child: GestureDetector(
              onTap: () => unawaited(
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              ),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  'Join',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.accent,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Reminder dropdown ────────────────────────────────────────────────────────

class _ReminderDropdown extends StatelessWidget {
  const _ReminderDropdown({required this.value, required this.onChanged});
  final int? value;
  final ValueChanged<int?> onChanged;

  static const _options = [5, 10, 15, 30, 60, 120, 360, 720, 1440];

  static String _label(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    return '$h ${h == 1 ? 'hour' : 'hours'}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.separator,
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int?>(
          value: value,
          isDense: true,
          dropdownColor: c.surfacePanel,
          style: TextStyle(color: c.textPrimary, fontSize: 12),
          items: [
            DropdownMenuItem<int?>(
              value: null,
              child: Text('No reminder',
                  style: TextStyle(color: c.textPrimary, fontSize: 12)),
            ),
            ..._options.map((m) => DropdownMenuItem<int?>(
                  value: m,
                  child: Text(
                    _label(m),
                    style: TextStyle(color: c.textPrimary, fontSize: 12),
                  ),
                )),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ─── Labeled field ────────────────────────────────────────────────────────────

class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: SizedBox(
            width: 68,
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
        Expanded(child: child),
      ],
    );
  }
}

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
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
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

class _Footer extends StatelessWidget {
  const _Footer({
    required this.isEditing,
    required this.onSave,
    required this.onClose,
    this.onForward,
    this.readOnly = false,
    this.hoveredUrl,
  });
  final bool isEditing;
  final VoidCallback onSave;
  final VoidCallback onClose;

  /// Offered only in [readOnly] — forwarding is what an attendee does with
  /// somebody else's meeting. The organizer adds a guest by typing them into
  /// the Guests field and saving, which is a different thing: their own event
  /// changes, rather than a copy of it going out from them.
  final VoidCallback? onForward;
  final bool readOnly;
  /// The real URL under the pointer while hovering a link in the dialog,
  /// shown at the bottom of the window alongside Close/Save/Cancel.
  final String? hoveredUrl;

  Widget _hoveredUrlLabel(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Text(
        hoveredUrl ?? '',
        style: TextStyle(color: c.textMuted, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (readOnly) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _hoveredUrlLabel(context),
            if (onForward != null) ...[
              TextButton.icon(
                onPressed: onForward,
                icon: Icon(Icons.forward_to_inbox_rounded,
                    size: 14, color: c.textMuted),
                label: Text('Forward',
                    style: TextStyle(color: c.textMuted, fontSize: 13)),
              ),
              const SizedBox(width: 8),
            ],
            TextButton(
              onPressed: onClose,
              child: Text('Close', style: TextStyle(color: c.textMuted, fontSize: 13)),
            ),
          ],
        ),
      );
    }
    return BlocBuilder<EventEditBloc, EventEditState>(
      builder: (context, state) {
        final isSaving = state is EventEditSaving;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              _hoveredUrlLabel(context),
              TextButton(
                onPressed: isSaving ? null : onClose,
                child: Text(
                  'Cancel',
                  style: TextStyle(color: c.textMuted, fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: isSaving ? null : onSave,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: isSaving
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: Colors.white),
                      )
                    : Icon(
                        isEditing ? Icons.check_rounded : Icons.add_rounded,
                        size: 14),
                label: Text(
                  isSaving
                      ? 'Saving…'
                      : (isEditing ? 'Save changes' : 'Save Event'),
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
