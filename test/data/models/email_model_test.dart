import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';

void main() {
  // Regression: a delta-sync poll that hit one message without
  // receivedDateTime populated used to throw inside EmailModel.fromJson,
  // discarding the entire batch (including genuinely new mail in the same
  // response) and — because the crash happened before the delta token was
  // saved — repeating on every subsequent poll indefinitely.
  group('EmailModel.fromJson', () {
    Map<String, dynamic> baseJson({Object? receivedDateTime = '2026-06-01T12:00:00Z'}) => {
          'id': 'msg-1',
          'subject': 'Hello',
          'from': {'emailAddress': {'address': 'a@b.com', 'name': 'A'}},
          'toRecipients': <dynamic>[],
          'ccRecipients': <dynamic>[],
          'bodyPreview': 'preview',
          'isRead': false,
          'receivedDateTime': receivedDateTime,
          'importance': 'normal',
        };

    test('parses normally when receivedDateTime is present', () {
      final email = EmailModel.fromJson(baseJson());
      expect(email.receivedDateTime, DateTime.parse('2026-06-01T12:00:00Z'));
    });

    test('falls back instead of throwing when receivedDateTime is null', () {
      final email = EmailModel.fromJson(baseJson(receivedDateTime: null));
      expect(email.id, 'msg-1');
      expect(email.receivedDateTime, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('falls back instead of throwing when receivedDateTime is unparseable', () {
      final email = EmailModel.fromJson(baseJson(receivedDateTime: 'not-a-date'));
      expect(email.receivedDateTime, DateTime.fromMillisecondsSinceEpoch(0));
    });

    group('meeting invite', () {
      // Graph returns DateTimeTimeZone without a Z suffix (getEmail sends
      // Prefer: outlook.timezone="UTC"), so the parser has to append one.
      Map<String, dynamic> declineJson({Map<String, dynamic>? proposedNewTime}) => {
            ...baseJson(),
            '@odata.type': '#microsoft.graph.eventMessageResponse',
            'meetingMessageType': 'meetingDeclined',
            'startDateTime': {'dateTime': '2026-08-04T01:30:00.0000000', 'timeZone': 'UTC'},
            'endDateTime': {'dateTime': '2026-08-04T02:00:00.0000000', 'timeZone': 'UTC'},
            'proposedNewTime': ?proposedNewTime,
          };

      test('reads a decline carrying proposedNewTime as a proposal', () {
        final email = EmailModel.fromJson(declineJson(proposedNewTime: {
          'start': {'dateTime': '2026-08-05T01:30:00.0000000', 'timeZone': 'UTC'},
          'end': {'dateTime': '2026-08-05T02:00:00.0000000', 'timeZone': 'UTC'},
        }));

        final invite = email.meetingInvite!;
        expect(invite.type, MeetingEmailType.proposedNewTime);
        expect(invite.proposedStart, DateTime.utc(2026, 8, 5, 1, 30));
        expect(invite.proposedEnd, DateTime.utc(2026, 8, 5, 2, 0));
        // The meeting's own times stay put — they locate the event to move.
        expect(invite.meetingStart, DateTime.utc(2026, 8, 4, 1, 30));
        expect(invite.meetingEnd, DateTime.utc(2026, 8, 4, 2, 0));
      });

      test('parses the proposed slot as UTC, not local time', () {
        final email = EmailModel.fromJson(declineJson(proposedNewTime: {
          'start': {'dateTime': '2026-08-05T01:30:00.0000000', 'timeZone': 'UTC'},
          'end': {'dateTime': '2026-08-05T02:00:00.0000000', 'timeZone': 'UTC'},
        }));

        expect(email.meetingInvite!.proposedStart!.isUtc, isTrue);
      });

      test('leaves a plain decline as a decline notification', () {
        final email = EmailModel.fromJson(declineJson());

        expect(email.meetingInvite!.type, MeetingEmailType.declineNotification);
        expect(email.meetingInvite!.proposedStart, isNull);
      });

      test('keeps a decline whose proposed slot is unusable as a decline', () {
        // Reclassifying would offer an Accept button with no time to accept.
        final email = EmailModel.fromJson(declineJson(proposedNewTime: {
          'start': {'dateTime': 'not-a-date', 'timeZone': 'UTC'},
          'end': {'dateTime': 'not-a-date', 'timeZone': 'UTC'},
        }));

        expect(email.meetingInvite!.type, MeetingEmailType.declineNotification);
      });

      test('keeps a decline with only half a proposed slot as a decline', () {
        final email = EmailModel.fromJson(declineJson(proposedNewTime: {
          'start': {'dateTime': '2026-08-05T01:30:00.0000000', 'timeZone': 'UTC'},
        }));

        expect(email.meetingInvite!.type, MeetingEmailType.declineNotification);
      });

      test('ignores proposedNewTime on a meeting request', () {
        // Only a decline can carry a counter-proposal; an invitation must keep
        // showing the attendee RSVP buttons.
        final email = EmailModel.fromJson({
          ...declineJson(proposedNewTime: {
            'start': {'dateTime': '2026-08-05T01:30:00.0000000', 'timeZone': 'UTC'},
            'end': {'dateTime': '2026-08-05T02:00:00.0000000', 'timeZone': 'UTC'},
          }),
          'meetingMessageType': 'meetingRequest',
        });

        expect(email.meetingInvite!.type, MeetingEmailType.invitation);
      });
    });
  });
}
