import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/timezone_utils.dart';
import '../../domain/entities/attendee_availability.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/calendar_recurrence.dart';
import '../../domain/usecases/check_attendees_availability.dart';
import '../../injection_container.dart';
import '../blocs/event_edit/event_edit_bloc.dart';
import '../blocs/event_edit/event_edit_event.dart';
import '../blocs/event_edit/event_edit_state.dart';
import 'recipient_input_field.dart';

// ─── Public API ──────────────────────────────────────────────────────────────

class EventEditDialog extends StatelessWidget {
  const EventEditDialog({
    super.key,
    this.event,
    this.initialStart,
    this.accountId,
  });

  final CalendarEvent? event;
  final DateTime? initialStart;
  final String? accountId;

  static Future<void> show(
    BuildContext context, {
    CalendarEvent? event,
    DateTime? initialStart,
    String? accountId,
  }) async {
    await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({
          'type': 'eventEdit',
          if (event != null) 'event': _eventToArgs(event),
          if (initialStart != null) 'initialStart': initialStart.toIso8601String(),
          if (accountId != null) 'accountId': accountId,
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
        if (e.location != null) 'location': e.location,
        if (e.bodyPreview != null) 'bodyPreview': e.bodyPreview,
        if (e.timezone != null) 'timezone': e.timezone,
        'attendees': e.attendees
            .map((a) => {
                  'email': a.email,
                  if (a.displayName != null) 'displayName': a.displayName,
                  'responseStatus': a.responseStatus.name,
                })
            .toList(),
        if (e.recurrence != null) 'recurrence': _recurrenceToArgs(e.recurrence!),
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
          width: 560,
          child: EventEditForm(
            event: event,
            initialStart: initialStart,
            accountId: accountId,
            onClose: () => Navigator.of(context).pop(false),
            checkAttendeesAvailability: sl<CheckAttendeesAvailability>(),
          ),
        ),
      ),
    );
  }
}

// ─── Form ─────────────────────────────────────────────────────────────────────

class EventEditForm extends StatefulWidget {
  const EventEditForm({
    super.key,
    this.event,
    this.initialStart,
    this.accountId,
    required this.onClose,
    this.onTitleChanged,
    this.checkAttendeesAvailability,
  });
  final CalendarEvent? event;
  final DateTime? initialStart;
  final String? accountId;
  final VoidCallback onClose;
  final ValueChanged<String>? onTitleChanged;
  final CheckAttendeesAvailability? checkAttendeesAvailability;

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
  late bool _isAllDay;
  late String _timezone;
  late List<String> _attendees;
  late CalendarRecurrence? _recurrence;

  List<AttendeeAvailability>? _availabilities;
  bool _checkingAvailability = false;
  Timer? _availabilityDebounce;

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    final now = DateTime.now();
    final roundedHour = DateTime(now.year, now.month, now.day, now.hour + 1);

    _titleController = TextEditingController(text: e?.subject ?? '');
    _locationController = TextEditingController(text: e?.location ?? '');
    _descriptionController = TextEditingController(text: e?.bodyPreview ?? '');

    _titleController.addListener(_onTitleChanged);
    widget.onTitleChanged?.call(_windowTitle);

    final defaultStart = widget.initialStart ?? roundedHour;
    final defaultEnd = widget.initialStart != null
        ? widget.initialStart!.add(const Duration(minutes: 30))
        : roundedHour.add(const Duration(hours: 1));

    final startLocal = (e?.start ?? defaultStart).toLocal();
    final endLocal = (e?.end ?? defaultEnd).toLocal();

    _startDate = DateTime(startLocal.year, startLocal.month, startLocal.day);
    _startTime = TimeOfDay(hour: startLocal.hour, minute: startLocal.minute);
    _endDate = DateTime(endLocal.year, endLocal.month, endLocal.day);
    _endTime = TimeOfDay(hour: endLocal.hour, minute: endLocal.minute);
    _isAllDay = e?.isAllDay ?? false;
    _timezone = e?.timezone ?? _localIanaTimezone();
    _attendees =
        e?.attendees.map((a) => a.email).toList() ?? const [];
    _recurrence = e?.recurrence;
  }

  @override
  void dispose() {
    _availabilityDebounce?.cancel();
    _titleController.removeListener(_onTitleChanged);
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  bool get _readOnly => widget.event != null;

  String get _baseTitle => widget.event == null ? 'New Event' : 'View Event';

  String get _windowTitle {
    final subject = _titleController.text.trim();
    return subject.isNotEmpty ? subject : _baseTitle;
  }

  void _onTitleChanged() {
    setState(() {});
    widget.onTitleChanged?.call(_windowTitle);
  }

  String _localIanaTimezone() => localIanaTimezone();

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

    final start = DateTime(
      _startDate.year, _startDate.month, _startDate.day,
      _startTime.hour, _startTime.minute,
    );
    final end = DateTime(
      _endDate.year, _endDate.month, _endDate.day,
      _endTime.hour, _endTime.minute,
    );
    if (!end.isAfter(start)) return;

    if (mounted) setState(() => _checkingAvailability = true);

    final emails = _attendees.map(_extractEmail).toList();
    final result = await checker(CheckAttendeesAvailabilityParams(
      emails: emails,
      start: start,
      end: end,
    ));

    if (!mounted) return;
    setState(() {
      _checkingAvailability = false;
      _availabilities = result.fold((_) => null, (a) => a);
    });
  }

  static final _emailInAngle = RegExp(r'<([^>]+)>');

  static String _extractEmail(String address) {
    final m = _emailInAngle.firstMatch(address);
    return m != null ? m.group(1)! : address;
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

    context.read<EventEditBloc>().add(EventEditSubmitted(
          id: widget.event?.id,
          subject: title,
          start: start,
          end: end,
          isAllDay: _isAllDay,
          timezone: _timezone,
          location: _locationController.text.trim().isNotEmpty
              ? _locationController.text.trim()
              : null,
          description: _descriptionController.text.trim().isNotEmpty
              ? _descriptionController.text.trim()
              : null,
          attendeeEmails: _attendees.map(_extractEmail).toList(),
          recurrence: _recurrence,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Column(
      mainAxisSize: MainAxisSize.min,
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
                          onStartDateChanged: (d) {
                            setState(() => _startDate = d);
                            _scheduleAvailabilityCheck();
                          },
                          onStartTimeChanged: (t) {
                            setState(() => _startTime = t);
                            _scheduleAvailabilityCheck();
                          },
                          onEndDateChanged: (d) {
                            setState(() => _endDate = d);
                            _scheduleAvailabilityCheck();
                          },
                          onEndTimeChanged: (t) {
                            setState(() => _endTime = t);
                            _scheduleAvailabilityCheck();
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      _AllDayToggle(
                        value: _isAllDay,
                        onChanged: (v) => setState(() => _isAllDay = v),
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
                          text: _locationController.text,
                          style: TextStyle(color: c.textPrimary, fontSize: 13),
                        )
                      : TextField(
                          controller: _locationController,
                          style: TextStyle(color: c.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Add location',
                            hintStyle:
                                TextStyle(color: c.textMuted, fontSize: 13),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            isDense: true,
                          ),
                        ),
                ),
                const SizedBox(height: 10),
                AbsorbPointer(
                  absorbing: _readOnly,
                  child: RecipientInputField(
                    label: 'Guests',
                    labelWidth: 68,
                    recipients: _attendees,
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
                if (!_readOnly && widget.checkAttendeesAvailability != null)
                  _AvailabilitySection(
                    attendees: _attendees,
                    availabilities: _availabilities,
                    checking: _checkingAvailability,
                  ),
                const SizedBox(height: 10),
                Divider(height: 1, color: c.separator),
                const SizedBox(height: 10),
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
          onClose: widget.onClose,
        ),
      ],
    );
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
            _DateButton(date: startDate, onTap: () => _pickStartDate(context)),
            if (!isAllDay) ...[
              const SizedBox(width: 6),
              _TimeButton(time: startTime, onTap: () => _pickStartTime(context)),
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
            _DateButton(date: endDate, onTap: () => _pickEndDate(context)),
            if (!isAllDay) ...[
              const SizedBox(width: 6),
              _TimeButton(time: endTime, onTap: () => _pickEndTime(context)),
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

  Future<void> _pickStartTime(BuildContext context) async {
    final t = await showTimePicker(context: context, initialTime: startTime);
    if (t != null) onStartTimeChanged(t);
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

  Future<void> _pickEndTime(BuildContext context) async {
    final t = await showTimePicker(context: context, initialTime: endTime);
    if (t != null) onEndTimeChanged(t);
  }
}

class _DateButton extends StatelessWidget {
  const _DateButton({required this.date, required this.onTap});
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

class _TimeButton extends StatelessWidget {
  const _TimeButton({required this.time, required this.onTap});
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
                        : null,
                    endDate: recurrence?.endDate,
                    count: recurrence?.count,
                  ));
                }
              },
            ),
            if (recurrence != null) ...[
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
        if (recurrence?.frequency == RecurrenceFrequency.weekly) ...[
          const SizedBox(height: 8),
          _DayOfWeekPicker(
            selected: recurrence!.daysOfWeek ?? [startDate.weekday],
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
          _DateButton(
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
  });

  final List<String> attendees;
  final List<AttendeeAvailability>? availabilities;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    if (attendees.isEmpty) return const SizedBox.shrink();

    final c = context.colors;

    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 68),
      child: checking
          ? Row(
              children: [
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
            )
          : availabilities == null
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: availabilities!
                      .where((a) => a.status != AttendeeAvailabilityStatus.unknown)
                      .map((a) => _AvailabilityRow(availability: a))
                      .toList(),
                ),
    );
  }
}

class _AvailabilityRow extends StatelessWidget {
  const _AvailabilityRow({required this.availability});
  final AttendeeAvailability availability;

  static const _statusLabels = {
    AttendeeAvailabilityStatus.free: 'Free',
    AttendeeAvailabilityStatus.tentative: 'Tentative',
    AttendeeAvailabilityStatus.busy: 'Busy',
    AttendeeAvailabilityStatus.outOfOffice: 'Out of office',
    AttendeeAvailabilityStatus.workingElsewhere: 'Working elsewhere',
    AttendeeAvailabilityStatus.unknown: '',
  };

  static Color _statusColor(AttendeeAvailabilityStatus s) => switch (s) {
        AttendeeAvailabilityStatus.free => const Color(0xFF34C759),
        AttendeeAvailabilityStatus.tentative => const Color(0xFFFF9F0A),
        AttendeeAvailabilityStatus.busy => const Color(0xFFFF3B30),
        AttendeeAvailabilityStatus.outOfOffice => const Color(0xFFFF3B30),
        AttendeeAvailabilityStatus.workingElsewhere => const Color(0xFF5E5CE6),
        AttendeeAvailabilityStatus.unknown => const Color(0xFF8E8E93),
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _statusColor(availability.status);
    final label = _statusLabels[availability.status] ?? '';
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
          Text(
            label,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

class _LinkifiedText extends StatefulWidget {
  const _LinkifiedText({required this.text, required this.style});
  final String text;
  final TextStyle style;

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  static final _urlPattern = RegExp(r'https?://[^\s<>"{}|\\^`\[\]]+');

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
        text: url,
        style: widget.style.copyWith(
          color: AppColors.accent,
          decoration: TextDecoration.underline,
          decorationColor: AppColors.accent,
        ),
        recognizer: recognizer,
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

class _Footer extends StatelessWidget {
  const _Footer({
    required this.isEditing,
    required this.onSave,
    required this.onClose,
    this.readOnly = false,
  });
  final bool isEditing;
  final VoidCallback onSave;
  final VoidCallback onClose;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (readOnly) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
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
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
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
