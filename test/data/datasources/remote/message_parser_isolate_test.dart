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
