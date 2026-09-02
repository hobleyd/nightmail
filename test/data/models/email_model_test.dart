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

    // Graph puts a message in exactly one folder, so its parent id *is* its
    // whole membership. Saying so keeps folder-scoped actions — deciding which
    // members of a thread a delete may touch — off the fallback path.
    group('folder membership', () {
      test('a Graph message belongs to its parent folder', () {
        final email = EmailModel.fromJson({
          ...baseJson(),
          'parentFolderId': 'AAMkAGinbox',
        });

        expect(email.folderIds, ['AAMkAGinbox']);
        expect(email.isInFolder('AAMkAGinbox'), isTrue);
        expect(email.isInFolder('AAMkAGsentitems'), isFalse);
      });

      test('a message with no parent folder reports no membership', () {
        final email = EmailModel.fromJson(baseJson());

        expect(email.folderIds, isEmpty);
      });

      // The cross-folder rows Graph adds to a folder listing always carry a
      // real parent id, which is what keeps them out of a delete scoped here.
      test('a message from another folder is not in the folder being viewed',
          () {
        final filed = EmailModel.fromJson({
          ...baseJson(),
          'parentFolderId': 'AAMkAGarchive',
        });

        expect(filed.isDeletableFrom('AAMkAGinbox'), isFalse);
        expect(filed.isDeletableFrom('AAMkAGarchive'), isTrue);
      });
    });

    // Outlook's "attach an email" produces an itemAttachment: no contentBytes,
    // and a `name` that is the attached message's subject, so it arrives with
    // no extension for the reading pane's chip to read a type off.
    group('attached email', () {
      EmailModel parseWithAttachment(Map<String, dynamic> attachment) =>
          EmailModel.fromJson({
            ...baseJson(),
            'hasAttachments': true,
            'attachments': [attachment],
          });

      test('names an itemAttachment .eml and types it message/rfc822', () {
        final email = parseWithAttachment({
          '@odata.type': '#microsoft.graph.itemAttachment',
          'id': 'att-1',
          'name': 'Re: Budget review',
          'size': 4096,
        });

        final attachment = email.attachments.single;
        expect(attachment.name, 'Re: Budget review.eml');
        expect(attachment.contentType, 'message/rfc822');
      });

      test('names an attachment already typed message/rfc822', () {
        final email = parseWithAttachment({
          'id': 'att-1',
          'name': 'Forwarded note',
          'contentType': 'message/rfc822',
          'size': 4096,
        });

        expect(email.attachments.single.name, 'Forwarded note.eml');
      });

      test('does not double up an extension the name already has', () {
        final email = parseWithAttachment({
          '@odata.type': '#microsoft.graph.itemAttachment',
          'id': 'att-1',
          'name': 'Report.eml',
          'size': 4096,
        });

        expect(email.attachments.single.name, 'Report.eml');
      });

      test('caps a runaway subject at 120 characters', () {
        final email = parseWithAttachment({
          '@odata.type': '#microsoft.graph.itemAttachment',
          'id': 'att-1',
          'name': 'x' * 300,
          'size': 4096,
        });

        expect(email.attachments.single.name, '${'x' * 120}.eml');
      });

      // The claim is deliberately narrow: an attachment Graph merely declined
      // to *type* must keep the open-externally behaviour that works today,
      // rather than being offered as an email and parsing to an empty one.
      test('leaves an untyped file attachment alone', () {
        final email = parseWithAttachment({
          '@odata.type': '#microsoft.graph.fileAttachment',
          'id': 'att-1',
          'name': 'scan',
          'size': 4096,
        });

        final attachment = email.attachments.single;
        expect(attachment.name, 'scan');
        expect(attachment.contentType, 'application/octet-stream');
      });

      test('leaves an ordinary file attachment alone', () {
        final email = parseWithAttachment({
          'id': 'att-1',
          'name': 'invoice.pdf',
          'contentType': 'application/pdf',
          'size': 4096,
        });

        final attachment = email.attachments.single;
        expect(attachment.name, 'invoice.pdf');
        expect(attachment.contentType, 'application/pdf');
      });
    });
  });
}
