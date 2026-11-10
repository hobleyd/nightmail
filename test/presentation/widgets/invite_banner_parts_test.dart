import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/calendar_recurrence.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';
import 'package:nightmail/presentation/widgets/invite_banner_parts.dart';

void main() {
  group('describeInviteRecurrence', () {
    test('is null for a one-off invitation', () {
      expect(describeInviteRecurrence(const MeetingInvite()), isNull);
    });

    test('describes the rule of a series invitation', () {
      expect(
        describeInviteRecurrence(const MeetingInvite(
          recurrence: CalendarRecurrence(
            frequency: RecurrenceFrequency.weekly,
            daysOfWeek: [2],
          ),
          isRecurring: true,
        )),
        'Weekly on Tue',
      );
    });

    test('still says it repeats when the rule could not be read', () {
      expect(
        describeInviteRecurrence(const MeetingInvite(isRecurring: true)),
        'Repeating',
      );
    });
  });
}
