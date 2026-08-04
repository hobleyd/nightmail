import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html_view/html_view.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/html_entities.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/calendar_event_attendee.dart';
import '../../domain/entities/calendar_recurrence.dart';

/// Wraps a calendar tile so dwelling on it opens a card with the whole meeting
/// spelled out — the point being that a tiled or short meeting shows almost
/// nothing on the tile itself.
///
/// Everything the card shows is already on the [CalendarEvent]: the calendar's
/// list fetch selects attendees, body preview, recurrence and reminder for
/// every provider. So this never makes a network call and has no loading state,
/// which is what lets the card ignore the pointer entirely (see [_hoverCard]).
class EventHoverTarget extends StatefulWidget {
  const EventHoverTarget({
    super.key,
    required this.event,
    required this.child,
    this.enabled = true,
  });

  final CalendarEvent event;

  /// Set false to suppress the card and dismiss one already open. Tiles pass
  /// `!isDragging` so a card can't hang over a meeting being dragged to a new
  /// time — the pointer stays on the tile throughout a drag, so nothing else
  /// would take it down.
  final bool enabled;

  final Widget child;

  @override
  State<EventHoverTarget> createState() => _EventHoverTargetState();
}

class _EventHoverTargetState extends State<EventHoverTarget> {
  /// Long enough that sweeping the pointer across a packed day doesn't strobe
  /// cards on and off, short enough to still feel like a reflex.
  static const _showDelay = Duration(milliseconds: 350);

  /// A grace period on the way out, only to stop the card blinking as the
  /// pointer crosses the hairline gutter between two tiled meetings.
  static const _hideDelay = Duration(milliseconds: 80);

  final _overlayController = OverlayPortalController();
  Timer? _showTimer;
  Timer? _hideTimer;
  bool _guardAcquired = false;

  /// The tile's rect in global coordinates, captured when the card opens. The
  /// card is positioned against this rather than following the tile, so it is
  /// dismissed on scroll instead of being left pointing at empty grid.
  Rect? _anchor;

  @override
  void didUpdateWidget(EventHoverTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _showTimer?.cancel();
      _hideTimer?.cancel();
      // Deferred: hiding rebuilds the OverlayPortal, and this runs while the
      // tile that owns it is already building.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hideNow();
      });
    }
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _releaseGuard();
    super.dispose();
  }

  void _releaseGuard() {
    if (_guardAcquired) {
      HtmlViewOverlayGuard.release();
      _guardAcquired = false;
    }
  }

  void _scheduleShow() {
    _hideTimer?.cancel();
    _showTimer?.cancel();
    if (!widget.enabled) return;
    _showTimer = Timer(_showDelay, _showNow);
  }

  void _showNow() {
    if (!mounted || !widget.enabled || _overlayController.isShowing) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    setState(() => _anchor = box.localToGlobal(Offset.zero) & box.size);
    // The calendar day panel shares the main window with the reading pane's
    // native WebView2, which paints over Flutter and isn't a ModalRoute the
    // html view can notice by itself.
    HtmlViewOverlayGuard.acquire();
    _guardAcquired = true;
    _overlayController.show();
  }

  void _scheduleHide() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, _hideNow);
  }

  void _hideNow() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    if (mounted && _overlayController.isShowing) {
      _overlayController.hide();
      _releaseGuard();
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _overlayController,
      overlayChildBuilder: _hoverCard,
      // Listener, not MouseRegion: a wheel event over the tile scrolls the grid
      // out from under the anchor. onPointerSignal doesn't claim the event, so
      // the enclosing scrollable still gets it.
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) _hideNow();
        },
        child: MouseRegion(
          onEnter: (_) => _scheduleShow(),
          onExit: (_) => _scheduleHide(),
          child: widget.child,
        ),
      ),
    );
  }

  Widget _hoverCard(BuildContext context) {
    final anchor = _anchor;
    if (anchor == null) return const SizedBox.shrink();
    // IgnorePointer keeps the card out of hit testing entirely, so it can be
    // laid over the tile it describes without stealing the hover that is
    // holding it open. Nothing on it is interactive.
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomSingleChildLayout(
          delegate: _EventCardLayout(anchor: anchor),
          child: EventDetailsCard(event: widget.event),
        ),
      ),
    );
  }
}

/// Places the card beside its tile: to the right where there is room, flipped
/// to the left where there isn't, and clamped into the window either way.
///
/// A layout delegate rather than a [CompositedTransformFollower] because
/// deciding which side fits needs the card's measured size, which only the
/// delegate is handed.
class _EventCardLayout extends SingleChildLayoutDelegate {
  const _EventCardLayout({required this.anchor});

  final Rect anchor;

  /// Clearance from the tile, and from the window edges.
  static const double _gap = 6;
  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(Size(
      math.min(EventDetailsCard.maxWidth, constraints.maxWidth - _margin * 2),
      math.max(0, constraints.maxHeight - _margin * 2),
    ));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final rightLimit = size.width - _margin - childSize.width;
    var x = anchor.right + _gap;
    if (x > rightLimit) {
      final flipped = anchor.left - _gap - childSize.width;
      x = flipped >= _margin ? flipped : rightLimit;
    }

    // Top-aligned with the tile, pushed back up when a meeting late in the day
    // would run the card off the bottom.
    final bottomLimit = math.max(_margin, size.height - _margin - childSize.height);
    final y = anchor.top.clamp(_margin, bottomLimit).toDouble();

    return Offset(
      x.clamp(_margin, math.max(_margin, rightLimit)).toDouble(),
      y,
    );
  }

  @override
  bool shouldRelayout(_EventCardLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}

/// The meeting, spelled out. Public so it can be pumped on its own.
class EventDetailsCard extends StatelessWidget {
  const EventDetailsCard({super.key, required this.event});

  final CalendarEvent event;

  static const double maxWidth = 320;

  /// Enough to see who is coming without the card outgrowing the window; the
  /// rest are counted off in a trailing line.
  static const int maxAttendeesShown = 8;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = eventColor(event);

    return Material(
      color: c.surfacePanel,
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minWidth: 200),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          // Tinted with the tile's own colour so the card reads as belonging to
          // the meeting under the pointer. Uniform on purpose — Flutter won't
          // take a rounded border whose sides differ, so the tile's heavier
          // left edge can't be echoed literally.
          border: Border.all(color: Color.alphaBlend(color.withAlpha(70), c.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: _rows(context, c, color),
        ),
      ),
    );
  }

  List<Widget> _rows(BuildContext context, AppColors c, Color color) {
    final rows = <Widget>[
      Text(
        event.subject,
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 4),
      Text(
        formatEventWhen(event),
        style: TextStyle(color: color, fontSize: 11, height: 1.3),
      ),
    ];

    void detail(IconData icon, String? text, {int maxLines = 2}) {
      if (text == null || text.isEmpty) return;
      rows.add(const SizedBox(height: 5));
      rows.add(_DetailRow(icon: icon, text: text, maxLines: maxLines));
    }

    detail(Icons.repeat_rounded, describeEventRecurrence(event));
    final location = event.location;
    detail(
      Icons.place_outlined,
      location == null ? null : displayEventLocation(location),
    );
    detail(Icons.notifications_none_rounded, describeEventReminder(event));
    detail(Icons.person_outline_rounded, describeEventParticipation(event));

    if (event.attendees.isNotEmpty) {
      rows.add(const SizedBox(height: 8));
      rows.add(Divider(height: 1, thickness: 1, color: c.separator));
      rows.add(const SizedBox(height: 6));
      rows.add(Text(
        'Attendees (${event.attendees.length})',
        style: TextStyle(
          color: c.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ));
      for (final a in event.attendees.take(maxAttendeesShown)) {
        rows.add(const SizedBox(height: 3));
        rows.add(_AttendeeRow(attendee: a));
      }
      final hidden = event.attendees.length - maxAttendeesShown;
      if (hidden > 0) {
        rows.add(const SizedBox(height: 3));
        rows.add(Text(
          '+$hidden more',
          style: TextStyle(color: c.textMuted, fontSize: 11),
        ));
      }
    }

    final preview = eventPreviewText(event.bodyPreview);
    if (preview.isNotEmpty) {
      rows.add(const SizedBox(height: 8));
      rows.add(Divider(height: 1, thickness: 1, color: c.separator));
      rows.add(const SizedBox(height: 6));
      rows.add(Text(
        preview,
        style: TextStyle(color: c.textTertiary, fontSize: 11, height: 1.35),
        maxLines: 5,
        overflow: TextOverflow.ellipsis,
      ));
    }

    return rows;
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.text,
    required this.maxLines,
  });

  final IconData icon;
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 12, color: c.textMuted),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: c.textSecondary, fontSize: 11, height: 1.3),
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _AttendeeRow extends StatelessWidget {
  const _AttendeeRow({required this.attendee});

  final CalendarEventAttendee attendee;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (icon, color) = switch (attendee.responseStatus) {
      AttendeeResponseStatus.accepted => (Icons.check_circle, _green),
      AttendeeResponseStatus.tentative => (Icons.help_rounded, _yellow),
      AttendeeResponseStatus.declined => (Icons.cancel, _red),
      AttendeeResponseStatus.none => (Icons.radio_button_unchecked, c.textDimmed),
    };

    return Row(
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            attendee.displayLabel,
            style: TextStyle(color: c.textSecondary, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

const _green = Color(0xFF34A853);
const _yellow = Color(0xFFFBBC04);
const _red = Color(0xFFEA4335);
const _grey = Color(0xFF9E9E9E);

/// Tile and card colour, driven by the user's [MeetingParticipation] so Gmail
/// and O365 meetings are coloured consistently (they expose different
/// underlying fields but map onto the same participation enum). Out-of-office
/// and working-elsewhere are free/busy states with no participation
/// equivalent, so they override as red/grey — these come from O365's `showAs`
/// only.
Color eventColor(CalendarEvent event) {
  if (event.status == CalendarEventStatus.outOfOffice) return _red;
  if (event.status == CalendarEventStatus.workingElsewhere) return _grey;

  return switch (event.participation) {
    MeetingParticipation.organizer => _green, // you organised it
    MeetingParticipation.accepted => AppColors.accent, // blue — you accepted
    MeetingParticipation.tentative => _yellow, // tentatively accepted
    MeetingParticipation.needsAction => _yellow, // invited, not yet responded
    MeetingParticipation.declined => _grey, // declined
    MeetingParticipation.none => AppColors.accent, // blue — on your calendar
  };
}

/// A Teams join URL is a wall of opaque query string that tells the reader
/// nothing, so it is shown as the bare join address.
String displayEventLocation(String location) {
  if (location.startsWith('https://teams.microsoft.com')) {
    return 'https://teams.microsoft.com/join-meeting';
  }
  return location;
}

/// When the meeting is: `Tue, 4 Aug · 9:00 AM – 9:30 AM · 30 min`, with
/// all-day and multi-day forms.
String formatEventWhen(CalendarEvent event) {
  final day = DateFormat('EEE, d MMM');
  final time = DateFormat('h:mm a');
  final start = event.start.toLocal();
  final end = event.end.toLocal();

  if (event.isAllDay) {
    // Providers model an all-day event's end as the following midnight, so the
    // last day it covers is a day back from there.
    final lastDay = end.subtract(const Duration(days: 1));
    if (lastDay.isAfter(start) && !_isSameDay(lastDay, start)) {
      return 'All day · ${day.format(start)} – ${day.format(lastDay)}';
    }
    return 'All day · ${day.format(start)}';
  }

  final length = formatEventDuration(end.difference(start));
  if (_isSameDay(start, end)) {
    return '${day.format(start)} · ${time.format(start)} – '
        '${time.format(end)} · $length';
  }
  return '${day.format(start)} ${time.format(start)} – '
      '${day.format(end)} ${time.format(end)} · $length';
}

/// `45 min`, `1 hr`, `1 hr 30 min`, `2 days 3 hr`.
String formatEventDuration(Duration duration) {
  if (duration.inMinutes <= 0) return '0 min';
  final days = duration.inDays;
  final hours = duration.inHours % 24;
  final minutes = duration.inMinutes % 60;
  return [
    if (days > 0) '$days ${days == 1 ? 'day' : 'days'}',
    if (hours > 0) '$hours hr',
    if (minutes > 0) '$minutes min',
  ].join(' ');
}

/// `Every 2 weeks on Mon, Wed until 30 Sep 2026`, or null for a one-off.
///
/// An occurrence whose series pattern couldn't be resolved still says so —
/// knowing a meeting repeats is worth more than the exact rule.
String? describeEventRecurrence(CalendarEvent event) {
  final r = event.recurrence;
  if (r == null) return event.isRecurringOccurrence ? 'Repeating' : null;

  final buffer = StringBuffer(r.interval <= 1
      ? switch (r.frequency) {
          RecurrenceFrequency.daily => 'Daily',
          RecurrenceFrequency.weekly => 'Weekly',
          RecurrenceFrequency.monthly => 'Monthly',
          RecurrenceFrequency.yearly => 'Yearly',
        }
      : switch (r.frequency) {
          RecurrenceFrequency.daily => 'Every ${r.interval} days',
          RecurrenceFrequency.weekly => 'Every ${r.interval} weeks',
          RecurrenceFrequency.monthly => 'Every ${r.interval} months',
          RecurrenceFrequency.yearly => 'Every ${r.interval} years',
        });

  final days = r.daysOfWeek;
  if (days != null && days.isNotEmpty && days.length < 7) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final listed = (days.where((d) => d >= 1 && d <= 7).toSet().toList()..sort())
        .map((d) => names[d - 1]);
    if (listed.isNotEmpty) buffer.write(' on ${listed.join(', ')}');
  }

  final endDate = r.endDate;
  if (endDate != null) {
    buffer.write(' until ${DateFormat('d MMM yyyy').format(endDate.toLocal())}');
  } else if (r.count != null) {
    buffer.write(' · ${r.count} times');
  }
  return buffer.toString();
}

/// `Reminder 15 min before`, or null when the meeting has no reminder.
String? describeEventReminder(CalendarEvent event) {
  final minutes = event.reminderMinutes;
  if (minutes == null) return null;
  if (minutes <= 0) return 'Reminder at start';
  if (minutes % 1440 == 0) {
    final days = minutes ~/ 1440;
    return 'Reminder ${days == 1 ? '1 day' : '$days days'} before';
  }
  if (minutes % 60 == 0) {
    final hours = minutes ~/ 60;
    return 'Reminder ${hours == 1 ? '1 hr' : '$hours hr'} before';
  }
  return 'Reminder $minutes min before';
}

/// Where the user stands in this meeting, or null when there's nothing to say
/// (an ordinary event on a subscribed calendar).
String? describeEventParticipation(CalendarEvent event) {
  if (event.status == CalendarEventStatus.outOfOffice) return 'Out of office';
  if (event.status == CalendarEventStatus.workingElsewhere) {
    return 'Working elsewhere';
  }

  return switch (event.participation) {
    MeetingParticipation.organizer => 'You organised this',
    MeetingParticipation.accepted => 'Accepted',
    MeetingParticipation.tentative => 'Tentative',
    MeetingParticipation.needsAction => 'Not responded',
    MeetingParticipation.declined => 'Declined',
    MeetingParticipation.none =>
      event.status == CalendarEventStatus.free ? 'Free' : null,
  };
}

/// Body text fit for a hover card. Google returns `description` as HTML where
/// Graph and CalDAV give plain text, so tags are stripped and blank lines
/// collapsed rather than showing markup. Entities are decoded after stripping,
/// so an escaped `&lt;b&gt;` can't turn into something that reads as a tag.
String eventPreviewText(String? bodyPreview) {
  if (bodyPreview == null || bodyPreview.isEmpty) return '';
  final text = decodeHtmlEntities(bodyPreview
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
          RegExp(r'</(p|div|li|tr|h[1-6])\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), ''));

  return text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
