import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/calendar_event_attendee.dart';
import '../../domain/entities/calendar_recurrence.dart';
import '../../domain/usecases/create_calendar_event.dart';
import '../../domain/usecases/update_calendar_event.dart';
import '../../injection_container.dart';
import '../blocs/event_edit/event_edit_bloc.dart';
import '../blocs/event_edit/event_edit_event.dart';
import '../blocs/event_edit/event_edit_state.dart';

// ─── Public API ──────────────────────────────────────────────────────────────

class EventEditDialog extends StatelessWidget {
  const EventEditDialog({super.key, this.event, this.initialStart});

  final CalendarEvent? event;
  final DateTime? initialStart;

  static Future<void> show(
    BuildContext context, {
    CalendarEvent? event,
    DateTime? initialStart,
  }) async {
    await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({
          'type': 'eventEdit',
          if (event != null) 'event': _eventToArgs(event),
          if (initialStart != null) 'initialStart': initialStart.toIso8601String(),
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
            onClose: () => Navigator.of(context).pop(false),
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
    required this.onClose,
  });
  final CalendarEvent? event;
  final DateTime? initialStart;
  final VoidCallback onClose;

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

  @override
  void initState() {
    super.initState();
    final e = widget.event;
    final now = DateTime.now();
    final roundedHour = DateTime(now.year, now.month, now.day, now.hour + 1);

    _titleController = TextEditingController(text: e?.subject ?? '');
    _locationController = TextEditingController(text: e?.location ?? '');
    _descriptionController = TextEditingController(text: e?.bodyPreview ?? '');

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
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  String _localIanaTimezone() {
    final offset = DateTime.now().timeZoneOffset;
    final name = DateTime.now().timeZoneName;
    // Try to match by abbreviated name in our list first.
    for (final tz in _kTimezones) {
      if (tz.abbreviation == name) return tz.iana;
    }
    // Fall back to offset matching.
    for (final tz in _kTimezones) {
      if (tz.offsetHours == offset.inHours) return tz.iana;
    }
    return 'UTC';
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
          attendeeEmails: _attendees,
          recurrence: _recurrence,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final title =
        widget.event == null ? 'New Event' : 'Edit Event';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TitleBar(title: title, onClose: widget.onClose),
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
                    autofocus: true,
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
                Row(
                  children: [
                    Expanded(
                      child: _DateTimeSection(
                        startDate: _startDate,
                        startTime: _startTime,
                        endDate: _endDate,
                        endTime: _endTime,
                        isAllDay: _isAllDay,
                        onStartDateChanged: (d) =>
                            setState(() => _startDate = d),
                        onStartTimeChanged: (t) =>
                            setState(() => _startTime = t),
                        onEndDateChanged: (d) =>
                            setState(() => _endDate = d),
                        onEndTimeChanged: (t) =>
                            setState(() => _endTime = t),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _AllDayToggle(
                      value: _isAllDay,
                      onChanged: (v) => setState(() => _isAllDay = v),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _LabeledField(
                  label: 'Timezone',
                  child: _TimezoneSelector(
                    value: _timezone,
                    onChanged: (tz) => setState(() => _timezone = tz),
                  ),
                ),
                const SizedBox(height: 10),
                Divider(height: 1, color: c.separator),
                const SizedBox(height: 10),
                _LabeledField(
                  label: 'Location',
                  child: TextField(
                    controller: _locationController,
                    style: TextStyle(color: c.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Add location',
                      hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _AttendeesField(
                  attendees: _attendees,
                  onChanged: (a) => setState(() => _attendees = a),
                ),
                const SizedBox(height: 10),
                Divider(height: 1, color: c.separator),
                const SizedBox(height: 10),
                _RecurrenceSection(
                  recurrence: _recurrence,
                  startDate: _startDate,
                  onChanged: (r) => setState(() => _recurrence = r),
                ),
                const SizedBox(height: 10),
                Divider(height: 1, color: c.separator),
                const SizedBox(height: 10),
                _LabeledField(
                  label: 'Notes',
                  child: TextField(
                    controller: _descriptionController,
                    maxLines: 4,
                    style: TextStyle(color: c.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Add notes',
                      hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
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

typedef _TzEntry = ({String iana, String label, String abbreviation, int offsetHours});

const List<_TzEntry> _kTimezones = [
  (iana: 'UTC', label: 'UTC', abbreviation: 'UTC', offsetHours: 0),
  (iana: 'America/New_York', label: 'Eastern (ET)', abbreviation: 'EST', offsetHours: -5),
  (iana: 'America/Chicago', label: 'Central (CT)', abbreviation: 'CST', offsetHours: -6),
  (iana: 'America/Denver', label: 'Mountain (MT)', abbreviation: 'MST', offsetHours: -7),
  (iana: 'America/Los_Angeles', label: 'Pacific (PT)', abbreviation: 'PST', offsetHours: -8),
  (iana: 'America/Anchorage', label: 'Alaska (AKT)', abbreviation: 'AKST', offsetHours: -9),
  (iana: 'Pacific/Honolulu', label: 'Hawaii (HT)', abbreviation: 'HST', offsetHours: -10),
  (iana: 'America/Toronto', label: 'Toronto', abbreviation: 'EST', offsetHours: -5),
  (iana: 'America/Vancouver', label: 'Vancouver', abbreviation: 'PST', offsetHours: -8),
  (iana: 'America/Sao_Paulo', label: 'São Paulo (BRT)', abbreviation: 'BRT', offsetHours: -3),
  (iana: 'America/Mexico_City', label: 'Mexico City', abbreviation: 'CST', offsetHours: -6),
  (iana: 'America/Buenos_Aires', label: 'Buenos Aires', abbreviation: 'ART', offsetHours: -3),
  (iana: 'Europe/London', label: 'London (GMT/BST)', abbreviation: 'GMT', offsetHours: 0),
  (iana: 'Europe/Paris', label: 'Paris (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Berlin', label: 'Berlin (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Rome', label: 'Rome (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Madrid', label: 'Madrid (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Amsterdam', label: 'Amsterdam (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Warsaw', label: 'Warsaw (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Stockholm', label: 'Stockholm (CET)', abbreviation: 'CET', offsetHours: 1),
  (iana: 'Europe/Helsinki', label: 'Helsinki (EET)', abbreviation: 'EET', offsetHours: 2),
  (iana: 'Europe/Athens', label: 'Athens (EET)', abbreviation: 'EET', offsetHours: 2),
  (iana: 'Europe/Istanbul', label: 'Istanbul (TRT)', abbreviation: 'TRT', offsetHours: 3),
  (iana: 'Europe/Moscow', label: 'Moscow (MSK)', abbreviation: 'MSK', offsetHours: 3),
  (iana: 'Asia/Dubai', label: 'Dubai (GST)', abbreviation: 'GST', offsetHours: 4),
  (iana: 'Asia/Kolkata', label: 'India (IST)', abbreviation: 'IST', offsetHours: 5),
  (iana: 'Asia/Dhaka', label: 'Dhaka (BST)', abbreviation: 'BST', offsetHours: 6),
  (iana: 'Asia/Bangkok', label: 'Bangkok (ICT)', abbreviation: 'ICT', offsetHours: 7),
  (iana: 'Asia/Shanghai', label: 'Beijing/Shanghai (CST)', abbreviation: 'CST', offsetHours: 8),
  (iana: 'Asia/Hong_Kong', label: 'Hong Kong (HKT)', abbreviation: 'HKT', offsetHours: 8),
  (iana: 'Asia/Singapore', label: 'Singapore (SGT)', abbreviation: 'SGT', offsetHours: 8),
  (iana: 'Asia/Taipei', label: 'Taipei (CST)', abbreviation: 'CST', offsetHours: 8),
  (iana: 'Asia/Seoul', label: 'Seoul (KST)', abbreviation: 'KST', offsetHours: 9),
  (iana: 'Asia/Tokyo', label: 'Tokyo (JST)', abbreviation: 'JST', offsetHours: 9),
  (iana: 'Australia/Perth', label: 'Perth (AWST)', abbreviation: 'AWST', offsetHours: 8),
  (iana: 'Australia/Adelaide', label: 'Adelaide (ACST)', abbreviation: 'ACST', offsetHours: 9),
  (iana: 'Australia/Brisbane', label: 'Brisbane (AEST)', abbreviation: 'AEST', offsetHours: 10),
  (iana: 'Australia/Sydney', label: 'Sydney (AEST)', abbreviation: 'AEST', offsetHours: 10),
  (iana: 'Australia/Melbourne', label: 'Melbourne (AEST)', abbreviation: 'AEST', offsetHours: 10),
  (iana: 'Pacific/Auckland', label: 'Auckland (NZST)', abbreviation: 'NZST', offsetHours: 12),
  (iana: 'Africa/Johannesburg', label: 'Johannesburg (SAST)', abbreviation: 'SAST', offsetHours: 2),
  (iana: 'Africa/Cairo', label: 'Cairo (EET)', abbreviation: 'EET', offsetHours: 2),
  (iana: 'Africa/Lagos', label: 'Lagos (WAT)', abbreviation: 'WAT', offsetHours: 1),
];

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
    final match = _kTimezones.where((t) => t.iana == widget.value).firstOrNull;
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
  late List<_TzEntry> _filtered;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filtered = _kTimezones;
    _search.addListener(_onSearch);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onSearch() {
    final q = _search.text.toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _kTimezones
          : _kTimezones
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
                itemCount: _filtered.length,
                itemBuilder: (_, i) {
                  final tz = _filtered[i];
                  final isSelected = tz.iana == widget.current;
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

// ─── Attendees field ──────────────────────────────────────────────────────────

class _AttendeesField extends StatefulWidget {
  const _AttendeesField({
    required this.attendees,
    required this.onChanged,
  });

  final List<String> attendees;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_AttendeesField> createState() => _AttendeesFieldState();
}

class _AttendeesFieldState extends State<_AttendeesField> {
  int? _selectedIndex;
  final _inputController = TextEditingController();
  final _inputFocus = FocusNode();
  final _chipFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(_AttendeesField old) {
    super.didUpdateWidget(old);
    if (_selectedIndex != null &&
        _selectedIndex! >= widget.attendees.length) {
      _selectedIndex = null;
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus.removeListener(_onFocusChanged);
    _inputFocus.dispose();
    _chipFocus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_inputFocus.hasFocus) _flush();
  }

  void _flush() {
    final text = _inputController.text
        .trim()
        .replaceAll(',', '')
        .replaceAll(';', '');
    if (text.isEmpty) return;
    final list = List<String>.from(widget.attendees)..add(text);
    _inputController.clear();
    widget.onChanged(list);
  }

  void _selectChip(int index) {
    setState(() => _selectedIndex = index);
    _chipFocus.requestFocus();
  }

  void _deleteSelected() {
    final idx = _selectedIndex;
    if (idx == null) return;
    final list = List<String>.from(widget.attendees)..removeAt(idx);
    setState(() => _selectedIndex = null);
    widget.onChanged(list);
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
            width: 68,
            child: Text(
              'Guests',
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
            focusNode: _chipFocus,
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
                _inputFocus.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                setState(() => _selectedIndex = null);
                _inputFocus.requestFocus();
              },
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (int i = 0; i < widget.attendees.length; i++)
                    _buildChip(i, c),
                  IntrinsicWidth(
                    child: Focus(
                      onKeyEvent: (_, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.backspace &&
                            _inputController.text.isEmpty &&
                            widget.attendees.isNotEmpty) {
                          _selectChip(widget.attendees.length - 1);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _inputController,
                        focusNode: _inputFocus,
                        style: TextStyle(color: c.textPrimary, fontSize: 13),
                        onSubmitted: (_) => _flush(),
                        onChanged: (v) {
                          if (v.endsWith(',') || v.endsWith(';')) _flush();
                        },
                        decoration: InputDecoration(
                          hintText: widget.attendees.isEmpty
                              ? 'Add guests by email'
                              : null,
                          hintStyle:
                              TextStyle(color: c.textMuted, fontSize: 13),
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
          ),
        ),
      ],
    );
  }

  Widget _buildChip(int index, AppColors c) {
    final email = widget.attendees[index];
    final isSelected = _selectedIndex == index;
    return GestureDetector(
      onTap: () => _selectChip(index),
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
          email,
          style: TextStyle(
            color: isSelected ? AppColors.accent : c.textSecondary,
            fontSize: 12,
          ),
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

// ─── Shared helpers ───────────────────────────────────────────────────────────

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
  });
  final bool isEditing;
  final VoidCallback onSave;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
