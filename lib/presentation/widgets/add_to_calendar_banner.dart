import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/meeting_conflicts.dart';
import '../../core/utils/timezone_utils.dart';
import '../../domain/entities/email.dart';
import '../../domain/usecases/create_calendar_event.dart';
import '../../domain/usecases/get_calendar_events.dart';
import '../../injection_container.dart';
import '../blocs/calendar/calendar_bloc.dart';
import '../blocs/calendar/calendar_event.dart';
import 'invite_banner_parts.dart';

/// What the state machine is up to. Deliberately not the reading pane's
/// `_InviteState`: there is no "proposing" here, and an added event has no
/// follow-up, so the whole flow is one press.
enum _AddState { idle, adding, added, failed }

/// Shown for a `METHOD:PUBLISH` calendar part — an event sent as information
/// rather than as an invitation, so the only thing to do with it is keep a copy.
///
/// Two things set it apart from the reading pane's other meeting banners:
///
///  * **It does not delete the email.** The others act on a meeting and then
///    file the message away, because an answered invitation is spent. A booking
///    confirmation or a ticket is the opposite — the event is a by-product and
///    the message is the thing worth keeping.
///  * **It checks first whether the event is already there.** Nothing else adds
///    a published event, so pressing the button twice makes two events; the
///    other banners are backed by provider operations that are idempotent about
///    the copy the provider itself added.
class AddToCalendarBanner extends StatefulWidget {
  const AddToCalendarBanner({super.key, required this.email});
  final Email email;

  @override
  State<AddToCalendarBanner> createState() => _AddToCalendarBannerState();
}

class _AddToCalendarBannerState extends State<AddToCalendarBanner> {
  _AddState _state = _AddState.idle;
  String? _errorMessage;
  bool _alreadyOnCalendar = false;

  @override
  void initState() {
    super.initState();
    _checkAlreadyAdded();
  }

  /// Looks for a copy of this event already on the calendar, so a message
  /// reopened after the event was added does not offer to add it again.
  ///
  /// Only ever suppresses the button — a lookup that fails, or an ICS with no
  /// `UID` to match on, leaves it offered. Adding a duplicate is recoverable;
  /// silently refusing to add an event the user asked for is not.
  Future<void> _checkAlreadyAdded() async {
    final invite = widget.email.meetingInvite;
    final start = invite?.meetingStart;
    final uid = invite?.uid;
    if (start == null || uid == null) return;
    final end = invite?.meetingEnd ?? start.add(const Duration(hours: 1));

    final result = await sl<GetCalendarEvents>()(GetCalendarEventsParams(
      startDateTime: start.subtract(const Duration(minutes: 1)),
      endDateTime: end,
    ));
    if (!mounted) return;
    result.fold((_) {}, (events) {
      if (events.any((e) => isSameMeetingUid(e.iCalUid, uid))) {
        setState(() => _alreadyOnCalendar = true);
      }
    });
  }

  Future<void> _add() async {
    final invite = widget.email.meetingInvite;
    final start = invite?.meetingStart;
    if (invite == null || start == null || _state == _AddState.adding) return;
    setState(() {
      _state = _AddState.adding;
      _errorMessage = null;
    });

    final result = await sl<CreateCalendarEvent>()(CreateCalendarEventParams(
      // The ICS is the only source for the title: unlike an invitation, whose
      // subject line the provider wrote, a published event travels inside a
      // message about something else ("Your booking is confirmed").
      subject: invite.summary?.trim().isNotEmpty == true
          ? invite.summary!.trim()
          : widget.email.subject,
      start: start,
      end: invite.meetingEnd ?? start.add(const Duration(hours: 1)),
      isAllDay: invite.isAllDay,
      // The parsed times are instants, and the datasources render them in the
      // reader's own zone — so that is the zone they must be labelled with.
      timezone: localIanaTimezone(),
      location: invite.location,
      description: invite.description,
    ));

    if (!mounted) return;
    result.fold(
      (failure) => setState(() {
        _state = _AddState.failed;
        _errorMessage = failure.message;
      }),
      (_) {
        setState(() => _state = _AddState.added);
        context.read<CalendarBloc>().add(
              CalendarWeekLoadRequested(
                  weekStart: context.read<CalendarBloc>().state.weekStart),
            );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final invite = widget.email.meetingInvite;
    final timeStr = invite != null ? formatMeetingTime(invite) : '';
    final title = invite?.summary?.trim();
    final location = invite?.location;

    final details = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.event_available_outlined,
              size: 14, color: c.textDimmed),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                timeStr.isNotEmpty ? timeStr : (title ?? 'Event'),
                style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
              if (title != null && title.isNotEmpty && timeStr.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(title,
                    style: TextStyle(color: c.textTertiary, fontSize: 11),
                    overflow: TextOverflow.ellipsis),
              ],
              if (location != null && location.isNotEmpty) ...[
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.place_outlined, size: 12, color: c.textDimmed),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(location,
                          style: TextStyle(color: c.textTertiary, fontSize: 11),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );

    final Widget trailing = switch (_state) {
      _AddState.adding => SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: AppColors.accent),
        ),
      _AddState.added => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline_rounded,
                size: 14, color: AppColors.accent),
            const SizedBox(width: 6),
            Text('Added to calendar',
                style: TextStyle(color: c.textTertiary, fontSize: 12)),
          ],
        ),
      _AddState.failed => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _errorMessage ?? 'Something went wrong',
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            InviteResponseButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              onPressed: () => setState(() => _state = _AddState.idle),
            ),
          ],
        ),
      _AddState.idle => _alreadyOnCalendar
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_available_rounded,
                    size: 14, color: c.textDimmed),
                const SizedBox(width: 6),
                Text('Already on your calendar',
                    style: TextStyle(color: c.textTertiary, fontSize: 12)),
              ],
            )
          : InviteResponseButton(
              label: 'Add to calendar',
              icon: Icons.calendar_month_rounded,
              onPressed: _add,
            ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      color: c.surfacePanel,
      // A Wrap for the same reason the invite banner uses one: in a narrow
      // reading pane the button keeps its intrinsic width and drops to its own
      // line, rather than starving the details column until the date wraps a
      // character at a time.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [details, trailing],
      ),
    );
  }
}
