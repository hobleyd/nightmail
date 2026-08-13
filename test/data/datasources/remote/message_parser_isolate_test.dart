import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/gmail_message_parser.dart';
import 'package:nightmail/data/datasources/remote/graph_message_parser.dart';
import 'package:nightmail/data/datasources/remote/imap_datasource_impl.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';

/// Covers the seams introduced by moving message parsing onto background
/// isolates. The end-to-end behaviour of each provider is already covered
/// through its datasource; what is new here is the boundary itself — the raw
/// MIME round-trip IMAP now does, and the "what still needs fetching" reports
/// that let the caller finish the job without decoding a response twice.

String _b64Url(String s) =>
    base64Url.encode(utf8.encode(s)).replaceAll('=', '');

void main() {
  group('parseFullImapMessage — raw MIME round-trip', () {
    // The riskiest part of the move: the fetched message is not sent across the
    // boundary (it is a lazily-parsed object graph), it is re-parsed from its
    // rendered source. Anything the MIME does not carry has to travel beside it.
    const rawMime = 'From: Alice <alice@example.com>\r\n'
        'To: me@example.com\r\n'
        'Cc: bob@example.com\r\n'
        'Subject: Quarterly report\r\n'
        'Date: Mon, 03 Aug 2026 09:15:00 +1000\r\n'
        'MIME-Version: 1.0\r\n'
        'Content-Type: text/html; charset=utf-8\r\n'
        '\r\n'
        '<p>Body text</p>';

    test('decodes the body, subject and addresses', () {
      final email = ImapDatasourceImpl.parseFullImapMessage(
        const ImapFullMessageParams(
          rawMime: rawMime,
          folderId: 'INBOX',
          uid: 42,
          isRead: true,
        ),
      );

      expect(email.subject, 'Quarterly report');
      expect(email.body, contains('<p>Body text</p>'));
      expect(email.bodyType, EmailBodyType.html);
      expect(email.from.address, 'alice@example.com');
      expect(email.from.name, 'Alice');
      expect(email.ccRecipients.single.address, 'bob@example.com');
    });

    test('takes the uid and read flag from the FETCH, not the MIME', () {
      // Neither is representable in MIME, so a message rebuilt from source
      // alone would report uid 0 and unread — and the id is derived from the
      // uid, so getting this wrong would mis-key the whole cache row.
      final email = ImapDatasourceImpl.parseFullImapMessage(
        const ImapFullMessageParams(
          rawMime: rawMime,
          folderId: 'Archive',
          uid: 1234,
          isRead: true,
        ),
      );

      expect(email.id, 'Archive:1234');
      expect(email.isRead, isTrue);
      expect(email.parentFolderId, 'Archive');
      expect(email.folderIds, ['Archive']);
    });

    test('prefers the date decoded by the fetching isolate', () {
      final fetched = DateTime.utc(2026, 1, 2, 3, 4);
      final email = ImapDatasourceImpl.parseFullImapMessage(
        ImapFullMessageParams(
          rawMime: rawMime,
          folderId: 'INBOX',
          uid: 1,
          isRead: false,
          receivedAt: fetched,
        ),
      );

      expect(email.receivedDateTime, fetched);
      expect(email.isRead, isFalse);
    });

    test('carries an inline image through as decoded bytes', () {
      // The base64 decode of inline images is the single most expensive step
      // this change moves, so it has to survive the round-trip.
      final imageBytes = List<int>.generate(48, (i) => i);
      final raw = 'From: alice@example.com\r\n'
          'Subject: With image\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: multipart/related; boundary=bnd\r\n'
          '\r\n'
          '--bnd\r\n'
          'Content-Type: text/html; charset=utf-8\r\n'
          '\r\n'
          '<img src="cid:img1">\r\n'
          '--bnd\r\n'
          'Content-Type: image/png\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          'Content-Disposition: inline\r\n'
          'Content-Id: <img1>\r\n'
          '\r\n'
          '${base64.encode(imageBytes)}\r\n'
          '--bnd--\r\n';

      final email = ImapDatasourceImpl.parseFullImapMessage(
        ImapFullMessageParams(
          rawMime: raw,
          folderId: 'INBOX',
          uid: 7,
          isRead: false,
        ),
      );

      expect(email.inlineAttachments, hasLength(1));
      expect(email.inlineAttachments.single.contentId, contains('img1'));
      expect(email.inlineAttachments.single.contentBytes, imageBytes);
    });
  });

  group('parseGmailFullMessage — follow-up work reported to the caller', () {
    Map<String, dynamic> message(Map<String, dynamic> payload) => {
          'id': 'm1',
          'threadId': 't1',
          'labelIds': ['INBOX'],
          'snippet': '',
          'payload': payload,
        };

    test('reports an ICS attachment that was not inlined', () {
      final parsed = parseGmailFullMessage(jsonEncode(message({
        'mimeType': 'multipart/mixed',
        'headers': <dynamic>[],
        'parts': [
          {
            'mimeType': 'text/plain',
            'body': {'data': _b64Url('hello')},
          },
          {
            'mimeType': 'text/calendar',
            'filename': 'invite.ics',
            'body': {'attachmentId': 'ics-att-1'},
          },
        ],
      })));

      expect(parsed.icsAttachmentId, 'ics-att-1');
      expect(parsed.email.meetingInvite, isNull);
    });

    test('does not report an ICS that was already inlined', () {
      const ics = 'BEGIN:VCALENDAR\r\nMETHOD:CANCEL\r\nEND:VCALENDAR';
      final parsed = parseGmailFullMessage(jsonEncode(message({
        'mimeType': 'multipart/mixed',
        'headers': <dynamic>[],
        'parts': [
          {
            'mimeType': 'text/calendar',
            'body': {'data': _b64Url(ics)},
          },
        ],
      })));

      expect(parsed.icsAttachmentId, isNull);
      expect(parsed.email.meetingInvite?.type, MeetingEmailType.cancellation);
    });

    test('reports an inline image too large for Gmail to inline', () {
      final parsed = parseGmailFullMessage(jsonEncode(message({
        'mimeType': 'multipart/related',
        'headers': <dynamic>[],
        'parts': [
          {
            'mimeType': 'text/html',
            'body': {'data': _b64Url('<img src="cid:big1">')},
          },
          {
            'mimeType': 'image/png',
            'headers': [
              {'name': 'Content-Id', 'value': '<big1>'},
            ],
            // attachmentId with no data — the >2 MB case.
            'body': {'attachmentId': 'att-big-1', 'size': 3000000},
          },
        ],
      })));

      expect(parsed.pendingInline, hasLength(1));
      expect(parsed.pendingInline.single.attachmentId, 'att-big-1');
      expect(parsed.pendingInline.single.contentId, '<big1>');
      // Not already present, or it would render twice.
      expect(parsed.email.inlineAttachments, isEmpty);
    });

    test('reports nothing further for a plain message', () {
      final parsed = parseGmailFullMessage(jsonEncode(message({
        'mimeType': 'text/plain',
        'headers': [
          {'name': 'Subject', 'value': 'Plain'},
        ],
        'body': {'data': _b64Url('just text')},
      })));

      expect(parsed.icsAttachmentId, isNull);
      expect(parsed.pendingInline, isEmpty);
      expect(parsed.email.body, 'just text');
    });
  });

  group('parseGraphFullMessage — inline attachments needing a fetch', () {
    Map<String, dynamic> message(List<Map<String, dynamic>> attachments) => {
          'id': 'g1',
          'subject': 'Hi',
          'from': {
            'emailAddress': {'address': 'a@b.com', 'name': 'A'}
          },
          'toRecipients': <dynamic>[],
          'ccRecipients': <dynamic>[],
          'bodyPreview': '',
          'isRead': true,
          'receivedDateTime': '2026-01-01T00:00:00Z',
          'importance': 'normal',
          'hasAttachments': attachments.isNotEmpty,
          'parentFolderId': 'inbox',
          'attachments': attachments,
        };

    test(r'reports inline attachments, since $expand cannot return their bytes',
        () {
      final parsed = parseGraphFullMessage(jsonEncode(message([
        {'id': 'att-1', 'name': 'logo.png', 'isInline': true},
        {'id': 'att-2', 'name': 'report.pdf', 'isInline': false},
      ])));

      expect(parsed.pendingInlineAttachmentIds, ['att-1']);
      // The non-inline one is a normal attachment chip, not a pending fetch.
      expect(parsed.email.attachments.single.name, 'report.pdf');
    });

    test('skips an inline attachment whose bytes were already present', () {
      final parsed = parseGraphFullMessage(jsonEncode(message([
        {
          'id': 'att-1',
          'name': 'logo.png',
          'isInline': true,
          'contentId': 'logo',
          'contentBytes': base64.encode([1, 2, 3]),
        },
      ])));

      expect(parsed.pendingInlineAttachmentIds, isEmpty);
      expect(parsed.email.inlineAttachments.single.contentBytes, [1, 2, 3]);
    });

    test('reports nothing for a message with no attachments', () {
      final parsed = parseGraphFullMessage(jsonEncode(message([])));
      expect(parsed.pendingInlineAttachmentIds, isEmpty);
      expect(parsed.icsAttachmentId, isNull);
    });

    test('reports a calendar attachment, whose bytes are never in the message',
        () {
      final parsed = parseGraphFullMessage(jsonEncode(message([
        {'id': 'att-1', 'name': 'agenda.pdf', 'isInline': false},
        {
          'id': 'att-2',
          'name': 'event.ics',
          'contentType': 'text/calendar; method=PUBLISH',
          'isInline': false,
        },
      ])));

      expect(parsed.icsAttachmentId, 'att-2');
    });

    test('recognises an .ics sent as application/octet-stream', () {
      final parsed = parseGraphFullMessage(jsonEncode(message([
        {
          'id': 'att-1',
          'name': 'Booking.ics',
          'contentType': 'application/octet-stream',
          'isInline': false,
        },
      ])));

      expect(parsed.icsAttachmentId, 'att-1');
    });
  });

  group('parseGraphIcsAttachment', () {
    test('classifies a fetched METHOD:PUBLISH part', () {
      const ics = 'BEGIN:VCALENDAR\r\n'
          'METHOD:PUBLISH\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:pub-1\r\n'
          'SUMMARY:Season opener\r\n'
          'DTSTART:20260901T090000Z\r\n'
          'DTEND:20260901T100000Z\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR';
      final invite = parseGraphIcsAttachment(jsonEncode({
        'contentBytes': base64.encode(utf8.encode(ics)),
      }))!;

      expect(invite.type, MeetingEmailType.publishedEvent);
      expect(invite.summary, 'Season opener');
      expect(invite.meetingStart, DateTime.utc(2026, 9, 1, 9));
    });

    // A bulk sender's invite.ics on a message Exchange never processed into a
    // meeting: there is no eventMessage and no calendar event, so the only
    // honest offer is "Add to calendar" — which is what publishedEvent draws.
    test('treats a fetched METHOD:REQUEST as an event to keep', () {
      const ics = 'BEGIN:VCALENDAR\r\n'
          'METHOD:REQUEST\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:req-1\r\n'
          'SUMMARY:Your NIB health check\r\n'
          'DESCRIPTION:Bring your member number\r\n'
          'LOCATION:Level 3\r\n'
          'DTSTART:20260901T090000Z\r\n'
          'DTEND:20260901T093000Z\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR';
      final invite = parseGraphIcsAttachment(jsonEncode({
        'contentBytes': base64.encode(utf8.encode(ics)),
      }))!;

      expect(invite.type, MeetingEmailType.publishedEvent);
      // The banner builds the event from these alone, so they have to be here:
      // a plain invitation leaves them null and takes them from the provider.
      expect(invite.summary, 'Your NIB health check');
      expect(invite.description, 'Bring your member number');
      expect(invite.location, 'Level 3');
      expect(invite.uid, 'req-1');
      expect(invite.meetingStart, DateTime.utc(2026, 9, 1, 9));
    });

    // The banner falls back to the email's subject on a null summary, so a
    // placeholder title here is indistinguishable from a real one and the event
    // lands on the calendar literally named "(No title)".
    test('reports no title rather than a placeholder when the ICS has none', () {
      const ics = 'BEGIN:VCALENDAR\r\n'
          'METHOD:REQUEST\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:req-2\r\n'
          'DTSTART:20260901T090000Z\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR';
      final invite = parseGraphIcsAttachment(jsonEncode({
        'contentBytes': base64.encode(utf8.encode(ics)),
      }))!;

      expect(invite.summary, isNull);
    });

    test('reads a title Exchange qualified with a LANGUAGE parameter', () {
      const ics = 'BEGIN:VCALENDAR\r\n'
          'METHOD:REQUEST\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:req-3\r\n'
          'SUMMARY;LANGUAGE=en-AU:Your NIB health check\r\n'
          'DTSTART:20260901T090000Z\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR';
      final invite = parseGraphIcsAttachment(jsonEncode({
        'contentBytes': base64.encode(utf8.encode(ics)),
      }))!;

      expect(invite.summary, 'Your NIB health check');
    });

    // No METHOD at all is the same case: a calendar file, nothing to answer.
    test('treats a fetched part with no METHOD as an event to keep', () {
      const ics = 'BEGIN:VCALENDAR\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:none-1\r\n'
          'SUMMARY:Booking confirmed\r\n'
          'DTSTART:20260901T090000Z\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR';
      final invite = parseGraphIcsAttachment(jsonEncode({
        'contentBytes': base64.encode(utf8.encode(ics)),
      }))!;

      expect(invite.type, MeetingEmailType.publishedEvent);
      expect(invite.summary, 'Booking confirmed');
    });

    // The reclassification must not reach the methods whose banners act through
    // the message id — getEmail drops anything but publishedEvent.
    test('leaves CANCEL, REPLY and COUNTER classified as themselves', () {
      MeetingEmailType typeOf(String method) {
        final ics = 'BEGIN:VCALENDAR\r\n'
            'METHOD:$method\r\n'
            'BEGIN:VEVENT\r\n'
            'UID:x-1\r\n'
            'DTSTART:20260901T090000Z\r\n'
            'END:VEVENT\r\n'
            'END:VCALENDAR';
        return parseGraphIcsAttachment(jsonEncode({
          'contentBytes': base64.encode(utf8.encode(ics)),
        }))!.type;
      }

      expect(typeOf('CANCEL'), MeetingEmailType.cancellation);
      expect(typeOf('REPLY'), MeetingEmailType.responseNotification);
      expect(typeOf('COUNTER'), MeetingEmailType.proposedNewTime);
    });

    test('returns null for a response carrying no bytes', () {
      expect(parseGraphIcsAttachment(jsonEncode({'name': 'x.ics'})), isNull);
      expect(parseGraphIcsAttachment('not json'), isNull);
    });
  });

  group('parseGraphInlineAttachments', () {
    test('decodes fetched attachment bodies', () {
      final result = parseGraphInlineAttachments([
        jsonEncode({
          'contentId': 'img1',
          'contentType': 'image/png',
          'contentBytes': base64.encode([9, 8, 7]),
        }),
      ]);

      expect(result.single.contentId, 'img1');
      expect(result.single.contentType, 'image/png');
      expect(result.single.contentBytes, [9, 8, 7]);
    });

    test('drops entries with no contentId to reference them by', () {
      final result = parseGraphInlineAttachments([
        jsonEncode({'contentBytes': base64.encode([1])}),
        jsonEncode({'contentId': '', 'contentBytes': base64.encode([1])}),
        'not json at all',
      ]);

      expect(result, isEmpty);
    });
  });

  group('graphDeltaLink', () {
    test('returns null while more pages remain', () {
      expect(
        graphDeltaLink('{"value":[],"@odata.nextLink":"https://x/next"}'),
        isNull,
      );
    });

    test('unescapes the slashes and ampersands Graph escapes', () {
      // Following the link verbatim otherwise 400s the next sync, which would
      // silently downgrade every later poll into a fresh 30-day bootstrap.
      const body = r'{"value":[],"@odata.deltaLink":'
          r'"https:\/\/graph.microsoft.com\/v1.0\/me\/mailFolders\/inbox'
          r'\/messages\/delta?$deltatoken=abc&$select=id"}';

      expect(
        graphDeltaLink(body),
        'https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta'
        r'?$deltatoken=abc&$select=id',
      );
    });
  });

  group('decodeGmailAttachmentBytes', () {
    test('decodes unpadded base64url', () {
      final bytes = List<int>.generate(10, (i) => i * 3);
      final raw = jsonEncode({
        'data': base64Url.encode(bytes).replaceAll('=', ''),
      });

      expect(decodeGmailAttachmentBytes(raw), bytes);
    });

    test('returns null rather than throwing on a body with no data', () {
      expect(decodeGmailAttachmentBytes(jsonEncode({'size': 0})), isNull);
      expect(decodeGmailAttachmentBytes('nonsense'), isNull);
    });
  });
}
