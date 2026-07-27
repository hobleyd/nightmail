import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/inline_attachment.dart';
import 'package:nightmail/domain/usecases/send_email.dart';
import 'package:nightmail/presentation/widgets/compose_body_builder.dart';

Email _makeEmail({
  String subject = 'Hello',
  String body = 'Body text',
  EmailBodyType bodyType = EmailBodyType.text,
  EmailAddress? from,
  List<EmailAddress> toRecipients = const [],
  List<EmailAddress> ccRecipients = const [],
}) {
  return Email(
    id: 'test-id',
    subject: subject,
    from: from ?? const EmailAddress(address: 'sender@example.com', name: 'Sender'),
    toRecipients: toRecipients,
    ccRecipients: ccRecipients,
    bodyPreview: '',
    body: body,
    bodyType: bodyType,
    isRead: true,
    receivedDateTime: DateTime.utc(2026, 7, 1, 10, 30),
    importance: EmailImportance.normal,
  );
}

void main() {
  group('ComposeBodyBuilder.buildInitialPlainBody', () {
    group('forward mode', () {
      test('includes To and Cc when both are present', () {
        final email = _makeEmail(
          toRecipients: [const EmailAddress(address: 'to@example.com', name: 'To Person')],
          ccRecipients: [const EmailAddress(address: 'cc@example.com', name: 'Cc Person')],
        );

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, contains('To: To Person <to@example.com>'));
        expect(result, contains('Cc: Cc Person <cc@example.com>'));
      });

      test('includes To but omits Cc when cc list is empty', () {
        final email = _makeEmail(
          toRecipients: [const EmailAddress(address: 'to@example.com')],
        );

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, contains('To: to@example.com'));
        expect(result, isNot(contains('Cc:')));
      });

      test('omits both To and Cc when recipient lists are empty', () {
        final email = _makeEmail();

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, isNot(contains('To:')));
        expect(result, isNot(contains('Cc:')));
      });

      test('header order is From → To → Cc → Date → Subject', () {
        final email = _makeEmail(
          toRecipients: [const EmailAddress(address: 'to@example.com')],
          ccRecipients: [const EmailAddress(address: 'cc@example.com')],
        );

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        final fromPos = result.indexOf('From:');
        final toPos = result.indexOf('To:');
        final ccPos = result.indexOf('Cc:');
        final datePos = result.indexOf('Date:');
        final subjectPos = result.indexOf('Subject:');

        expect(fromPos, lessThan(toPos));
        expect(toPos, lessThan(ccPos));
        expect(ccPos, lessThan(datePos));
        expect(datePos, lessThan(subjectPos));
      });

      test('includes forwarded message separator', () {
        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: _makeEmail(),
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, contains('---------- Forwarded message ---------'));
      });

      test('includes original plain text body', () {
        final email = _makeEmail(body: 'Original content here');

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, contains('Original content here'));
      });

      test('strips HTML tags from HTML body', () {
        final email = _makeEmail(
          body: '<p>Hello <b>world</b></p>',
          bodyType: EmailBodyType.html,
        );

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, contains('Hello world'));
        expect(result, isNot(contains('<p>')));
        expect(result, isNot(contains('<b>')));
      });

      test('formats multiple To recipients as comma-separated', () {
        final email = _makeEmail(
          toRecipients: [
            const EmailAddress(address: 'a@example.com'),
            const EmailAddress(address: 'b@example.com'),
          ],
        );

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, contains('To: a@example.com, b@example.com'));
      });
    });

    group('reply mode', () {
      test('includes To and Cc when both are present', () {
        final email = _makeEmail(
          toRecipients: [const EmailAddress(address: 'to@example.com', name: 'To Person')],
          ccRecipients: [const EmailAddress(address: 'cc@example.com')],
        );

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.reply,
        );

        expect(result, contains('To: To Person <to@example.com>'));
        expect(result, contains('Cc: cc@example.com'));
      });

      test('includes To but omits Cc when cc list is empty', () {
        final email = _makeEmail(
          toRecipients: [const EmailAddress(address: 'to@example.com')],
        );

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.reply,
        );

        expect(result, contains('To: to@example.com'));
        expect(result, isNot(contains('Cc:')));
      });

      test('omits both To and Cc when recipient lists are empty', () {
        final email = _makeEmail();

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.reply,
        );

        expect(result, isNot(contains('To:')));
        expect(result, isNot(contains('Cc:')));
      });

      test('includes the On...wrote header', () {
        final email = _makeEmail(
          from: const EmailAddress(address: 'sender@example.com', name: 'Sender'),
        );

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.reply,
        );

        expect(result, contains('Sender <sender@example.com> wrote:'));
      });

      test('quotes plain text body with > prefix', () {
        final email = _makeEmail(body: 'line one\nline two');

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.reply,
        );

        expect(result, contains('> line one'));
        expect(result, contains('> line two'));
      });

      test('replyAll behaves same as reply for header lines', () {
        final email = _makeEmail(
          toRecipients: [const EmailAddress(address: 'to@example.com')],
          ccRecipients: [const EmailAddress(address: 'cc@example.com')],
        );

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.replyAll,
        );

        expect(result, contains('To: to@example.com'));
        expect(result, contains('Cc: cc@example.com'));
      });
    });

    group('other modes', () {
      test('returns empty string for newEmail mode', () {
        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: _makeEmail(),
          draftEmail: null,
          mode: ComposeMode.newEmail,
        );

        expect(result, isEmpty);
      });

      test('returns empty string when originalEmail is null', () {
        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: null,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, isEmpty);
      });

      test('returns draft body when draftEmail is provided', () {
        final draft = _makeEmail(body: 'Draft content');

        final result = ComposeBodyBuilder.buildInitialPlainBody(
          originalEmail: _makeEmail(body: 'Original'),
          draftEmail: draft,
          mode: ComposeMode.forward,
        );

        expect(result, equals('Draft content'));
        expect(result, isNot(contains('Original')));
      });
    });
  });

  group('ComposeBodyBuilder.buildInitialHtmlBody', () {
    group('forward mode', () {
      test('includes To and Cc divs when both are present', () {
        final email = _makeEmail(
          toRecipients: [const EmailAddress(address: 'to@example.com', name: 'To Person')],
          ccRecipients: [const EmailAddress(address: 'cc@example.com')],
          bodyType: EmailBodyType.html,
          body: '<div>original</div>',
        );

        final result = ComposeBodyBuilder.buildInitialHtmlBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, contains('<div>To: To Person &lt;to@example.com&gt;</div>'));
        expect(result, contains('<div>Cc: cc@example.com</div>'));
      });

      test('omits To and Cc divs when recipient lists are empty', () {
        final email = _makeEmail(bodyType: EmailBodyType.html, body: '<div>hi</div>');

        final result = ComposeBodyBuilder.buildInitialHtmlBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, isNot(contains('<div>To:')));
        expect(result, isNot(contains('<div>Cc:')));
      });

      test('HTML-escapes angle brackets in addresses', () {
        final email = _makeEmail(
          toRecipients: [const EmailAddress(address: 'to@example.com', name: 'Alice')],
          bodyType: EmailBodyType.html,
          body: '',
        );

        final result = ComposeBodyBuilder.buildInitialHtmlBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, contains('Alice &lt;to@example.com&gt;'));
        expect(result, isNot(contains('Alice <to@example.com>')));
      });

      test('includes forwarded message separator div', () {
        final result = ComposeBodyBuilder.buildInitialHtmlBody(
          originalEmail: _makeEmail(bodyType: EmailBodyType.html, body: ''),
          draftEmail: null,
          mode: ComposeMode.forward,
        );

        expect(result, contains('<div>---------- Forwarded message ---------</div>'));
      });
    });

    group('reply mode', () {
      test('includes To and Cc divs when both are present', () {
        final email = _makeEmail(
          toRecipients: [const EmailAddress(address: 'to@example.com')],
          ccRecipients: [const EmailAddress(address: 'cc@example.com')],
          bodyType: EmailBodyType.html,
          body: '<div>original</div>',
        );

        final result = ComposeBodyBuilder.buildInitialHtmlBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.reply,
        );

        expect(result, contains('<div>To: to@example.com</div>'));
        expect(result, contains('<div>Cc: cc@example.com</div>'));
      });

      test('omits To and Cc divs when recipient lists are empty', () {
        final email = _makeEmail(bodyType: EmailBodyType.html, body: '<div>hi</div>');

        final result = ComposeBodyBuilder.buildInitialHtmlBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.reply,
        );

        expect(result, isNot(contains('<div>To:')));
        expect(result, isNot(contains('<div>Cc:')));
      });

      test('wraps body in blockquote', () {
        final email = _makeEmail(
          bodyType: EmailBodyType.html,
          body: '<div>quoted</div>',
        );

        final result = ComposeBodyBuilder.buildInitialHtmlBody(
          originalEmail: email,
          draftEmail: null,
          mode: ComposeMode.reply,
        );

        expect(result, contains('<blockquote'));
        expect(result, contains('<div>quoted</div>'));
        expect(result, contains('</blockquote>'));
      });

      test('includes original message separator div', () {
        final result = ComposeBodyBuilder.buildInitialHtmlBody(
          originalEmail: _makeEmail(bodyType: EmailBodyType.html, body: ''),
          draftEmail: null,
          mode: ComposeMode.reply,
        );

        expect(result, contains('<div>---------- Original Message ----------</div>'));
      });
    });
  });

  group('ComposeBodyBuilder.formatAddress', () {
    test('returns name and address when name is present', () {
      const addr = EmailAddress(address: 'user@example.com', name: 'Alice');
      expect(ComposeBodyBuilder.formatAddress(addr), 'Alice <user@example.com>');
    });

    test('returns address only when name is null', () {
      const addr = EmailAddress(address: 'user@example.com');
      expect(ComposeBodyBuilder.formatAddress(addr), 'user@example.com');
    });

    test('returns address only when name is empty string', () {
      const addr = EmailAddress(address: 'user@example.com', name: '');
      expect(ComposeBodyBuilder.formatAddress(addr), 'user@example.com');
    });
  });

  group('ComposeBodyBuilder.formatAddressList', () {
    test('returns empty string for empty list', () {
      expect(ComposeBodyBuilder.formatAddressList([]), isEmpty);
    });

    test('formats a single address', () {
      const addr = EmailAddress(address: 'a@example.com', name: 'Alice');
      expect(ComposeBodyBuilder.formatAddressList([addr]), 'Alice <a@example.com>');
    });

    test('joins multiple addresses with comma and space', () {
      const addresses = [
        EmailAddress(address: 'a@example.com', name: 'Alice'),
        EmailAddress(address: 'b@example.com'),
      ];
      expect(
        ComposeBodyBuilder.formatAddressList(addresses),
        'Alice <a@example.com>, b@example.com',
      );
    });
  });

  group('ComposeBodyBuilder.resolveCidImages', () {
    final png = InlineAttachment(
      contentId: '<image002.png@01DD1DDB.2F326CA0>',
      contentType: 'image/png',
      contentBytes: Uint8List.fromList([1, 2, 3]),
    );
    final expectedUrl = 'data:image/png;base64,${base64Encode(png.contentBytes)}';

    test('swaps a cid: src for a data: URL and records the content id', () {
      const html = '<p><img width="1092" id="Picture_x0020_6" '
          'src="cid:image002.png@01DD1DDB.2F326CA0"></p>';

      final result = ComposeBodyBuilder.resolveCidImages(html, [png]);

      expect(result, contains('src="$expectedUrl"'));
      expect(result, contains('data-cid="image002.png@01DD1DDB.2F326CA0"'));
      expect(result, isNot(contains('cid:image002.png')));
      // Unrelated attributes survive.
      expect(result, contains('width="1092"'));
      expect(result, contains('id="Picture_x0020_6"'));
    });

    test('matches a Content-Id given without angle brackets', () {
      final attachment = InlineAttachment(
        contentId: 'logo@example.com',
        contentType: 'image/gif',
        contentBytes: Uint8List.fromList([9]),
      );

      final result = ComposeBodyBuilder.resolveCidImages(
          '<img src="cid:logo@example.com">', [attachment]);

      expect(result, contains('data:image/gif;base64,'));
      expect(result, contains('data-cid="logo@example.com"'));
    });

    test('resolves a bare local part against a fully qualified Content-Id, '
        'tagging it with the qualified form the send path will re-attach', () {
      final attachment = InlineAttachment(
        contentId: '<ii_x@mail.gmail.com>',
        contentType: 'image/png',
        contentBytes: Uint8List.fromList([7]),
      );

      final result =
          ComposeBodyBuilder.resolveCidImages('<img src="cid:ii_x">', [attachment]);

      expect(result, contains('data-cid="ii_x@mail.gmail.com"'));
    });

    test('leaves references with no matching attachment untouched', () {
      // An Outlook thread quotes cids from messages several replies back
      // without re-attaching the parts; they were already broken on arrival.
      const html = '<img src="cid:image001.png@01DD1919.5D643CF0">';

      expect(ComposeBodyBuilder.resolveCidImages(html, [png]), html);
    });

    test('leaves single-quoted and self-closing tags well formed', () {
      final result = ComposeBodyBuilder.resolveCidImages(
          "<img src='cid:image002.png@01DD1DDB.2F326CA0' />", [png]);

      expect(result, contains('src="$expectedUrl"'));
      expect(result, endsWith('/>'));
    });

    test('does not touch non-image cid references or external images', () {
      const html = '<img src="https://example.com/logo.png">'
          '<a href="cid:image002.png@01DD1DDB.2F326CA0">link</a>';

      expect(ComposeBodyBuilder.resolveCidImages(html, [png]), html);
    });

    test('is a no-op when the message carries no inline attachments', () {
      const html = '<img src="cid:whatever">';
      expect(ComposeBodyBuilder.resolveCidImages(html, const []), html);
    });
  });

  group('buildInitialHtmlBody inline images', () {
    final attachment = InlineAttachment(
      contentId: '<image002.png@01DD1DDB.2F326CA0>',
      contentType: 'image/png',
      contentBytes: Uint8List.fromList([1, 2, 3]),
    );

    Email htmlEmailWithInlineImage() => Email(
          id: 'test-id',
          subject: 'Hello',
          from: const EmailAddress(address: 'sender@example.com'),
          toRecipients: const [],
          ccRecipients: const [],
          bodyPreview: '',
          body: '<html><body><p>See below</p>'
              '<img src="cid:image002.png@01DD1DDB.2F326CA0"></body></html>',
          bodyType: EmailBodyType.html,
          isRead: true,
          receivedDateTime: DateTime.utc(2026, 7, 24, 3, 57),
          importance: EmailImportance.normal,
          inlineAttachments: [attachment],
        );

    test('reply resolves the quoted body\'s inline images', () {
      final result = ComposeBodyBuilder.buildInitialHtmlBody(
        originalEmail: htmlEmailWithInlineImage(),
        draftEmail: null,
        mode: ComposeMode.reply,
      );

      expect(result, contains('data:image/png;base64,'));
      expect(result, contains('data-cid="image002.png@01DD1DDB.2F326CA0"'));
      expect(result, isNot(contains('src="cid:')));
    });

    test('forward resolves the quoted body\'s inline images', () {
      final result = ComposeBodyBuilder.buildInitialHtmlBody(
        originalEmail: htmlEmailWithInlineImage(),
        draftEmail: null,
        mode: ComposeMode.forward,
      );

      expect(result, contains('data:image/png;base64,'));
      expect(result, isNot(contains('src="cid:')));
    });

    test('a reopened draft resolves its own inline images', () {
      final result = ComposeBodyBuilder.buildInitialHtmlBody(
        originalEmail: null,
        draftEmail: htmlEmailWithInlineImage(),
        mode: ComposeMode.newEmail,
      );

      expect(result, contains('data:image/png;base64,'));
      expect(result, isNot(contains('src="cid:')));
    });
  });
}
