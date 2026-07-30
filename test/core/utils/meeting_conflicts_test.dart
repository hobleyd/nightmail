import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/meeting_conflicts.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';

/// The invited slot used throughout: 10:00–11:00 UTC.
final _inviteStart = DateTime.utc(2026, 7, 30, 10);
final _inviteEnd = DateTime.utc(2026, 7, 30, 11);
const _inviteUid = 'abc123uid@google.com';

CalendarEvent _event({
  required String id,
  required DateTime start,
  required DateTime end,
  CalendarEventStatus status = CalendarEventStatus.busy,
  String? iCalUid,
}) =>
    CalendarEvent(
      id: id,
      subject: id,
      start: start,
      end: end,
      isAllDay: false,
      status: status,
      iCalUid: iCalUid,
    );

List<String> _conflictIds(
  List<CalendarEvent> events, {
  String? inviteUid = _inviteUid,
}) =>
    findMeetingConflicts(
      events: events,
      meetingStart: _inviteStart,
      meetingEnd: _inviteEnd,
      inviteUid: inviteUid,
    ).map((e) => e.id).toList();

void main() {
  group('findMeetingConflicts — overlap', () {
    test('an event overlapping the invited slot is a conflict', () {
      final events = [
        _event(
          id: 'overlaps-start',
          start: DateTime.utc(2026, 7, 30, 9, 30),
          end: DateTime.utc(2026, 7, 30, 10, 30),
          iCalUid: 'other-meeting@google.com',
        ),
      ];

      expect(_conflictIds(events), ['overlaps-start']);
    });

    test('an event wholly containing the invited slot is a conflict', () {
      final events = [
        _event(
          id: 'all-day-workshop',
          start: DateTime.utc(2026, 7, 30, 8),
          end: DateTime.utc(2026, 7, 30, 17),
          iCalUid: 'workshop@google.com',
        ),
      ];

      expect(_conflictIds(events), ['all-day-workshop']);
    });

    test('back-to-back meetings do not clash', () {
      final events = [
        _event(
          id: 'ends-when-invite-starts',
          start: DateTime.utc(2026, 7, 30, 9),
          end: _inviteStart,
          iCalUid: 'earlier@google.com',
        ),
        _event(
          id: 'starts-when-invite-ends',
          start: _inviteEnd,
          end: DateTime.utc(2026, 7, 30, 12),
          iCalUid: 'later@google.com',
        ),
      ];

      expect(_conflictIds(events), isEmpty);
    });

    test('times are compared as instants, not wall clocks', () {
      // 20:00+10:00 is 10:00 UTC — the same instant the invite starts.
      final events = [
        _event(
          id: 'brisbane-evening',
          start: DateTime.parse('2026-07-30T20:30:00+10:00'),
          end: DateTime.parse('2026-07-30T21:30:00+10:00'),
          iCalUid: 'brisbane@google.com',
        ),
      ];

      expect(_conflictIds(events), ['brisbane-evening']);
    });
  });

  group('findMeetingConflicts — free/busy', () {
    test('an event the user is free for does not clash', () {
      final events = [
        _event(
          id: 'marked-free',
          start: _inviteStart,
          end: _inviteEnd,
          status: CalendarEventStatus.free,
          iCalUid: 'free@google.com',
        ),
      ];

      expect(_conflictIds(events), isEmpty);
    });

    test('a working-location entry is a marker, not a commitment', () {
      final events = [
        _event(
          id: 'working-from-home',
          start: DateTime.utc(2026, 7, 30),
          end: DateTime.utc(2026, 7, 31),
          status: CalendarEventStatus.workingElsewhere,
          iCalUid: 'wfh@google.com',
        ),
      ];

      expect(_conflictIds(events), isEmpty);
    });

    test('tentative and out-of-office both clash', () {
      final events = [
        _event(
          id: 'tentative',
          start: _inviteStart,
          end: DateTime.utc(2026, 7, 30, 10, 15),
          status: CalendarEventStatus.tentative,
          iCalUid: 'tentative@google.com',
        ),
        _event(
          id: 'on-leave',
          start: DateTime.utc(2026, 7, 30),
          end: DateTime.utc(2026, 7, 31),
          status: CalendarEventStatus.outOfOffice,
          iCalUid: 'leave@google.com',
        ),
      ];

      expect(_conflictIds(events), ['tentative', 'on-leave']);
    });
  });

  group('findMeetingConflicts — the invite\'s own calendar copy', () {
    test('the copy the provider auto-added for this invite is not a clash', () {
      final events = [
        _event(
          id: 'auto-added-copy',
          start: _inviteStart,
          end: _inviteEnd,
          status: CalendarEventStatus.tentative, // Google: RSVP needsAction
          iCalUid: _inviteUid,
        ),
      ];

      expect(_conflictIds(events), isEmpty);
    });

    test('a recurring instance of the invited series is not a clash', () {
      // Google expands a series into instances whose iCalUID carries an
      // instance suffix, while the ICS on the invite holds the master UID.
      final events = [
        _event(
          id: 'this-series-instance',
          start: _inviteStart,
          end: _inviteEnd,
          iCalUid: 'abc123uid_20260730T100000Z@google.com',
        ),
      ];

      expect(_conflictIds(events), isEmpty);
    });

    test(
        'a different meeting occupying exactly the invited slot IS a clash '
        '(the common double-booking, previously discarded as "self")', () {
      final events = [
        _event(
          id: 'existing-standup',
          start: _inviteStart,
          end: _inviteEnd,
          iCalUid: 'standup@google.com',
        ),
      ];

      expect(_conflictIds(events), ['existing-standup']);
    });

    test('with no UID on either side, the exact-slot event is assumed to be '
        'the auto-added copy', () {
      // O365 invites carry no ICS part, so there is no UID to match on.
      final events = [
        _event(id: 'presumed-self', start: _inviteStart, end: _inviteEnd),
        _event(
          id: 'genuine-overlap',
          start: DateTime.utc(2026, 7, 30, 10, 30),
          end: DateTime.utc(2026, 7, 30, 11, 30),
        ),
      ];

      expect(_conflictIds(events, inviteUid: null), ['genuine-overlap']);
    });

    test('UID matching ignores case and surrounding whitespace', () {
      final events = [
        _event(
          id: 'auto-added-copy',
          start: _inviteStart,
          end: _inviteEnd,
          iCalUid: '  ABC123UID@google.com ',
        ),
      ];

      expect(_conflictIds(events), isEmpty);
    });
  });
}
