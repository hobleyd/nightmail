import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/imap_datasource_impl.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/auth/imap_credential_storage.dart';

/// Builds a leaf [BodyPart] the way enough_mail's BODYSTRUCTURE parser does:
/// the header objects are constructed from the bare media-type/disposition
/// token and their parameters are then attached via `setParameter` (which
/// leaves `ContentDispositionHeader.filename` null and preserves the server's
/// parameter-name casing). Building them this way — rather than from a full
/// raw header string — is what makes these tests reflect real fetch output.
BodyPart _leaf(
  String mediaType, {
  String? disposition,
  // Parameter name deliberately overridable so tests can reproduce servers
  // that send e.g. `NAME`/`FILENAME` in caps.
  String nameParam = 'name',
  String? name,
  String dispositionFilenameParam = 'filename',
  String? dispositionFilename,
  String? cid,
  int? size,
}) {
  final contentType = ContentTypeHeader(mediaType);
  if (name != null) contentType.setParameter(nameParam, name);
  final part = BodyPart()..contentType = contentType;
  if (disposition != null) {
    final header = ContentDispositionHeader(disposition);
    if (dispositionFilename != null) {
      header.setParameter(dispositionFilenameParam, dispositionFilename);
    }
    part.contentDisposition = header;
  }
  if (cid != null) part.cid = cid;
  if (size != null) part.size = size;
  return part;
}

MimeMessage _multipart(String subtype, List<BodyPart> children) {
  final root = BodyPart()..contentType = ContentTypeHeader('multipart/$subtype');
  for (final child in children) {
    root.addPart(child);
  }
  return MimeMessage()..body = root;
}

Mailbox _mb(
  String path, {
  required String sep,
  List<MailboxFlag> flags = const [],
}) =>
    Mailbox(
      encodedName: path.contains(sep) ? path.substring(path.lastIndexOf(sep) + 1) : path,
      encodedPath: path,
      flags: List<MailboxFlag>.from(flags),
      pathSeparator: sep,
    );

void main() {
  group('ImapDatasourceImpl.detectNamespaceConvention', () {
    // -----------------------------------------------------------------------
    // Courier IMAP (sep = '.')
    // -----------------------------------------------------------------------

    test('Courier abbreviated namespace: prefixes with INBOX.', () {
      final mailboxes = [
        _mb('INBOX', sep: '.', flags: [MailboxFlag.inbox, MailboxFlag.hasNoChildren]),
        _mb('Sent', sep: '.', flags: [MailboxFlag.sent, MailboxFlag.hasNoChildren]),
        _mb('Drafts', sep: '.', flags: [MailboxFlag.drafts, MailboxFlag.hasNoChildren]),
        _mb('Trash', sep: '.', flags: [MailboxFlag.trash, MailboxFlag.hasNoChildren]),
      ];

      final result = ImapDatasourceImpl.detectNamespaceConvention(mailboxes);

      expect(result.pathSeparator, equals('.'));
      expect(result.inboxFolderPrefix, equals('INBOX.'));
    });

    test('Dovecot with dot separator and full paths: no prefix', () {
      final mailboxes = [
        _mb('INBOX', sep: '.', flags: [MailboxFlag.inbox, MailboxFlag.hasChildren]),
        _mb('INBOX.Sent', sep: '.', flags: [MailboxFlag.sent, MailboxFlag.hasNoChildren]),
        _mb('INBOX.Drafts', sep: '.', flags: [MailboxFlag.drafts, MailboxFlag.hasNoChildren]),
        _mb('INBOX.Trash', sep: '.', flags: [MailboxFlag.trash, MailboxFlag.hasNoChildren]),
      ];

      final result = ImapDatasourceImpl.detectNamespaceConvention(mailboxes);

      expect(result.pathSeparator, equals('.'));
      expect(result.inboxFolderPrefix, isEmpty);
    });

    // -----------------------------------------------------------------------
    // Gmail IMAP (sep = '/')
    // -----------------------------------------------------------------------

    test('Gmail without user labels: no prefix', () {
      final mailboxes = [
        _mb('INBOX', sep: '/', flags: [MailboxFlag.inbox, MailboxFlag.hasNoChildren]),
        _mb('[Gmail]', sep: '/', flags: [MailboxFlag.noSelect, MailboxFlag.hasChildren]),
      ];

      final result = ImapDatasourceImpl.detectNamespaceConvention(mailboxes);

      expect(result.pathSeparator, equals('/'));
      expect(result.inboxFolderPrefix, isEmpty);
    });

    test('Gmail with user labels: labels are not prefixed with INBOX/', () {
      // Gmail labels appear at root but are real folders, not INBOX children.
      // INBOX has \HasNoChildren on Gmail (no INBOX/* subfolders exist).
      final mailboxes = [
        _mb('INBOX', sep: '/', flags: [MailboxFlag.inbox, MailboxFlag.hasNoChildren]),
        _mb('[Gmail]', sep: '/', flags: [MailboxFlag.noSelect, MailboxFlag.hasChildren]),
        _mb('MyLabel', sep: '/', flags: [MailboxFlag.hasNoChildren]),
        _mb('AnotherLabel', sep: '/', flags: [MailboxFlag.hasNoChildren]),
      ];

      final result = ImapDatasourceImpl.detectNamespaceConvention(mailboxes);

      expect(result.pathSeparator, equals('/'));
      expect(result.inboxFolderPrefix, isEmpty);
    });

    // -----------------------------------------------------------------------
    // woodgatebeach: Dovecot (mail.woodgatebeach.org.au) with '.' separator
    // and full INBOX.* paths — \HasChildren restored by CHILDREN return option
    // -----------------------------------------------------------------------

    test('woodgatebeach Dovecot full-path server: LIST "" % returns only INBOX with HasChildren', () {
      // Verified against mail.woodgatebeach.org.au:
      //   LIST "" "%" RETURN (STATUS (MESSAGES UNSEEN) CHILDREN)
      //   → * LIST (\HasChildren) "." INBOX
      // Without CHILDREN in RETURN, \HasChildren was dropped and the BFS
      // would not expand INBOX, leaving all subfolders invisible.
      final mailboxes = [
        _mb('INBOX', sep: '.', flags: [MailboxFlag.inbox, MailboxFlag.hasChildren]),
      ];

      final result = ImapDatasourceImpl.detectNamespaceConvention(mailboxes);

      // Single INBOX with HasChildren: no abbreviated namespace, just a
      // server that puts everything under INBOX.*.
      expect(result.pathSeparator, equals('.'));
      expect(result.inboxFolderPrefix, isEmpty);
    });

    test('woodgatebeach Dovecot: INBOX.Financial has HasChildren for second-level expansion', () {
      // After getChildFolders('INBOX'), INBOX.Financial appears with \HasChildren
      // (restored by CHILDREN return option). The BFS should expand it.
      final mailboxes = [
        _mb('INBOX.Financial', sep: '.', flags: [MailboxFlag.hasChildren]),
        _mb('INBOX.Sent', sep: '.', flags: [MailboxFlag.sent, MailboxFlag.hasNoChildren]),
        _mb('INBOX.Drafts', sep: '.', flags: [MailboxFlag.drafts, MailboxFlag.hasNoChildren]),
        _mb('INBOX.Trash', sep: '.', flags: [MailboxFlag.trash, MailboxFlag.hasChildren]),
      ];

      // INBOX.Financial.childFolderCount > 0 drives BFS — verify via hasChildren
      expect(mailboxes[0].hasChildren, isTrue);
      expect(mailboxes[1].hasChildren, isFalse);
    });

    // -----------------------------------------------------------------------
    // Hypothetical: Dovecot with '/' separator and abbreviated namespace
    // -----------------------------------------------------------------------

    test('abbreviated namespace with / separator: prefixes with INBOX/', () {
      // Dovecot can use '/' separator but still use Courier-style abbreviated
      // namespace. INBOX reports \HasChildren because real children (Sent etc.)
      // exist under INBOX/, even though they appear abbreviated at root level.
      final mailboxes = [
        _mb('INBOX', sep: '/', flags: [MailboxFlag.inbox, MailboxFlag.hasChildren]),
        _mb('Sent', sep: '/', flags: [MailboxFlag.sent, MailboxFlag.hasNoChildren]),
        _mb('Drafts', sep: '/', flags: [MailboxFlag.drafts, MailboxFlag.hasNoChildren]),
        _mb('Trash', sep: '/', flags: [MailboxFlag.trash, MailboxFlag.hasNoChildren]),
      ];

      final result = ImapDatasourceImpl.detectNamespaceConvention(mailboxes);

      expect(result.pathSeparator, equals('/'));
      expect(result.inboxFolderPrefix, equals('INBOX/'));
    });

    // -----------------------------------------------------------------------
    // Edge cases
    // -----------------------------------------------------------------------

    test('empty mailbox list returns dot separator and no prefix', () {
      final result = ImapDatasourceImpl.detectNamespaceConvention([]);

      expect(result.pathSeparator, equals('.'));
      expect(result.inboxFolderPrefix, isEmpty);
    });

    test('no INBOX in list: no prefix regardless of abbreviated-looking folders', () {
      final mailboxes = [
        _mb('Sent', sep: '.', flags: [MailboxFlag.sent]),
        _mb('Drafts', sep: '.', flags: [MailboxFlag.drafts]),
      ];

      final result = ImapDatasourceImpl.detectNamespaceConvention(mailboxes);

      expect(result.inboxFolderPrefix, isEmpty);
    });
  });

  group('ImapDatasourceImpl.collectAttachments', () {
    test('envelope-only message (no body, no parts) has no attachments', () {
      final msg = MimeMessage();
      expect(ImapDatasourceImpl.collectAttachments(msg), isEmpty);
    });

    test('reads the MIME headers of a BODY[]-only message (no BODYSTRUCTURE)',
        () {
      // parseFromText populates `parts` but not the BODYSTRUCTURE `body`, so
      // this exercises the header-walk path the reading pane uses.
      const raw = 'Subject: test\r\n'
          'Content-Type: multipart/mixed; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'hello\r\n'
          '--b\r\n'
          'Content-Type: application/pdf; name="doc.pdf"\r\n'
          'Content-Disposition: attachment; filename="doc.pdf"\r\n'
          '\r\n'
          'JVBER\r\n'
          '--b--\r\n';
      final msg = MimeMessage.parseFromText(raw);
      expect(msg.body, isNull); // no BODYSTRUCTURE from a text parse

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments, hasLength(1));
      expect(attachments.single.name, 'doc.pdf');
    });

    test(
        'BODY[]-only: finds an attachment declared only via Content-Type name '
        '(the reading-pane regression)', () {
      // The reading pane fetches BODY[] without BODYSTRUCTURE, so this is the
      // path it actually runs. It used to call
      // `findContentInfo(disposition: attachment)`, which matches only an
      // explicit Content-Disposition — this message has none, so the chips
      // vanished even though the list paperclip (BODYSTRUCTURE, which has the
      // filename fallback) lit up.
      const raw = 'Subject: test\r\n'
          'Content-Type: multipart/mixed; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'hello\r\n'
          '--b\r\n'
          'Content-Type: application/pdf; name="quote.pdf"\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          'JVBER\r\n'
          '--b--\r\n';
      final msg = MimeMessage.parseFromText(raw);
      expect(msg.body, isNull);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments, hasLength(1));
      expect(attachments.single.name, 'quote.pdf');
      expect(attachments.single.id, '2'); // part number for getPart/download
      expect(attachments.single.contentType, 'application/pdf');
    });

    test('BODY[]-only: numbers nested parts so getPart can fetch them', () {
      const raw = 'Subject: test\r\n'
          'Content-Type: multipart/mixed; boundary="out"\r\n'
          '\r\n'
          '--out\r\n'
          'Content-Type: multipart/alternative; boundary="in"\r\n'
          '\r\n'
          '--in\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'hello\r\n'
          '--in\r\n'
          'Content-Type: text/html\r\n'
          '\r\n'
          '<p>hello</p>\r\n'
          '--in--\r\n'
          '--out\r\n'
          'Content-Type: application/zip; name="bundle.zip"\r\n'
          '\r\n'
          'PK\r\n'
          '--out--\r\n';
      final msg = MimeMessage.parseFromText(raw);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments, hasLength(1));
      expect(attachments.single.name, 'bundle.zip');
      expect(attachments.single.id, '2');
    });

    // The live regression, captured from INBOX:5147: a *forwarded* message —
    // multipart/mixed whose second part is a message/rfc822 carrying the
    // original, whose own attachments are the ones the user wants. Every chip
    // came out numbered '2', so all four downloaded the enclosing forward
    // (1.3 MB of raw MIME) instead of their own file.
    //
    // The ids must round-trip through `getPart`, which is the half that makes
    // this a real download rather than a plausible-looking string — so the
    // test resolves each one rather than just asserting its shape.
    test('BODY[]-only: numbers attachments inside a forwarded message', () {
      const inner = 'Subject: original\r\n'
          'Content-Type: multipart/mixed; boundary="in"\r\n'
          '\r\n'
          '--in\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'the original note\r\n'
          '--in\r\n'
          'Content-Type: application/pdf; name="first.pdf"\r\n'
          'Content-Disposition: attachment; filename="first.pdf"\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          'JVBERg==\r\n'
          '--in\r\n'
          'Content-Type: application/pdf; name="second.pdf"\r\n'
          'Content-Disposition: attachment; filename="second.pdf"\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          'JVBERjI=\r\n'
          '--in--\r\n';
      final raw = 'Subject: FW: original\r\n'
          'Content-Type: multipart/mixed; boundary="out"\r\n'
          '\r\n'
          '--out\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'see attached\r\n'
          '--out\r\n'
          'Content-Type: message/rfc822\r\n'
          'Content-Disposition: attachment\r\n'
          'Content-Transfer-Encoding: 7bit\r\n'
          '\r\n'
          '$inner'
          '--out--\r\n';
      final msg = MimeMessage()
        ..mimeData = TextMimeData(raw, containsHeader: true);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      // The forward itself is an attachment (a .eml), then the two files
      // inside it — each addressed within the rfc822 part, not as it.
      expect(
        attachments.map((a) => '${a.id}=${a.name}'),
        <String>['2=Attachment', '2.2=first.pdf', '2.3=second.pdf'],
      );

      // Each id resolves to its own part, which is what downloadAttachment
      // does with it.
      final resolved = MimeMessage()
        ..mimeData = TextMimeData(raw, containsHeader: true);
      resolved.parse();
      expect(
        resolved.getPart('2.2')!.decodeContentBinary(),
        equals(utf8.encode('%PDF')),
      );
      expect(
        resolved.getPart('2.3')!.decodeContentBinary(),
        equals(utf8.encode('%PDF2')),
      );
    });

    test('BODY[]-only: works on an unparsed message, as the fetch delivers it',
        () {
      // `MimeMessage.parseFromText` parses eagerly, but the IMAP fetch parser
      // only assigns `mimeData` (see fetch_parser.dart: `message.mimeData =
      // TextMimeData(..., containsHeader: true)`) and leaves `parts` null until
      // something touches a header. `_parseToModel` calls collectAttachments
      // *before* it decodes the body, so the walk has to trigger that lazy
      // parse itself — otherwise it would see no parts and find nothing on the
      // real path while every eagerly-parsed test still passed.
      const raw = 'Subject: test\r\n'
          'Content-Type: multipart/mixed; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'hello\r\n'
          '--b\r\n'
          'Content-Type: application/pdf; name="lazy.pdf"\r\n'
          '\r\n'
          'JVBER\r\n'
          '--b--\r\n';
      final msg = MimeMessage()
        ..mimeData = TextMimeData(raw, containsHeader: true);
      expect(msg.parts, isNull, reason: 'not parsed yet, as after a fetch');

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments, hasLength(1));
      expect(attachments.single.name, 'lazy.pdf');
      expect(attachments.single.id, '2');
    });

    // The live regression, captured from INBOX:5082 (Apple Mail): photos sent
    // as `Content-Disposition: inline` with a filename but NO Content-Id. The
    // body cannot reference them, so treating "inline" as "the body renders
    // this" dropped them from the chips *and* from the inline images — they
    // appeared nowhere at all.
    test('BODY[]-only: offers an inline part with no Content-Id as a chip', () {
      const raw = 'Subject: Expense John Henderson\r\n'
          'Content-Type: multipart/mixed; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: text/plain; charset=us-ascii\r\n'
          '\r\n'
          'See attached\r\n'
          '--b\r\n'
          'Content-Type: image/jpeg; name="IMG_5857.jpeg"\r\n'
          'Content-Disposition: inline; filename="IMG_5857.jpeg"\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          '/9j/4AAQ\r\n'
          '--b\r\n'
          'Content-Type: text/plain; charset=us-ascii\r\n'
          '\r\n'
          'and another\r\n'
          '--b\r\n'
          'Content-Type: image/jpeg; name="IMG_5858.jpeg"\r\n'
          'Content-Disposition: inline; filename="IMG_5858.jpeg"\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          '/9j/4AAQ\r\n'
          '--b--\r\n';
      final msg = MimeMessage()
        ..mimeData = TextMimeData(raw, containsHeader: true);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments.map((a) => a.name),
          <String>['IMG_5857.jpeg', 'IMG_5858.jpeg']);
      expect(attachments.map((a) => a.id), <String>['2', '4']);
      expect(attachments.first.contentType, 'image/jpeg');
    });

    test('BODYSTRUCTURE: offers an inline part with no Content-Id as a chip',
        () {
      // Same message shape as above, arriving on the list path — so the
      // paperclip agrees with the reading pane instead of contradicting it.
      final msg = _multipart('mixed', [
        _leaf('text/plain'),
        _leaf('image/jpeg',
            disposition: 'inline',
            dispositionFilename: 'IMG_5857.jpeg',
            size: 120000),
        _leaf('text/plain'),
        _leaf('image/jpeg',
            disposition: 'inline',
            dispositionFilename: 'IMG_5858.jpeg',
            size: 130000),
      ]);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments.map((a) => a.name),
          <String>['IMG_5857.jpeg', 'IMG_5858.jpeg']);
      expect(attachments.map((a) => a.id), <String>['2', '4']);
    });

    test('does not turn an inline-labelled HTML body into a chip', () {
      // Some mailers label the body `inline; filename="message.html"`. Since a
      // filename alone is now enough to make a cid-less part a chip, the body
      // has to be excluded explicitly or every such email grows a bogus chip.
      const raw = 'Subject: test\r\n'
          'Content-Type: multipart/mixed; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: text/html\r\n'
          'Content-Disposition: inline; filename="message.html"\r\n'
          '\r\n'
          '<p>hello</p>\r\n'
          '--b\r\n'
          'Content-Type: application/pdf; name="real.pdf"\r\n'
          '\r\n'
          'JVBER\r\n'
          '--b--\r\n';
      final msg = MimeMessage()
        ..mimeData = TextMimeData(raw, containsHeader: true);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments.map((a) => a.name), <String>['real.pdf']);
    });

    test('still offers a text part the sender explicitly marked attachment',
        () {
      const raw = 'Subject: test\r\n'
          'Content-Type: multipart/mixed; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'see log\r\n'
          '--b\r\n'
          'Content-Type: text/plain; name="server.log"\r\n'
          'Content-Disposition: attachment; filename="server.log"\r\n'
          '\r\n'
          'line 1\r\n'
          '--b--\r\n';
      final msg = MimeMessage()
        ..mimeData = TextMimeData(raw, containsHeader: true);

      expect(ImapDatasourceImpl.collectAttachments(msg).map((a) => a.name),
          <String>['server.log']);
    });

    test('offers a text/calendar invite declared only by name', () {
      const raw = 'Subject: invite\r\n'
          'Content-Type: multipart/mixed; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: text/plain\r\n'
          '\r\n'
          'you are invited\r\n'
          '--b\r\n'
          'Content-Type: text/calendar; method=REQUEST; name="meeting.ics"\r\n'
          '\r\n'
          'BEGIN:VCALENDAR\r\n'
          '--b--\r\n';
      final msg = MimeMessage()
        ..mimeData = TextMimeData(raw, containsHeader: true);

      expect(ImapDatasourceImpl.collectAttachments(msg).map((a) => a.name),
          <String>['meeting.ics']);
    });

    test('BODY[]-only: skips inline cid images and the text body parts', () {
      const raw = 'Subject: test\r\n'
          'Content-Type: multipart/related; boundary="b"\r\n'
          '\r\n'
          '--b\r\n'
          'Content-Type: text/html\r\n'
          '\r\n'
          '<img src="cid:logo@x">\r\n'
          '--b\r\n'
          'Content-Type: image/png; name="logo.png"\r\n'
          'Content-Id: <logo@x>\r\n'
          '\r\n'
          'iVBOR\r\n'
          '--b--\r\n';
      final msg = MimeMessage.parseFromText(raw);

      expect(ImapDatasourceImpl.collectAttachments(msg), isEmpty);
    });

    test('single text/plain message has no attachments', () {
      final msg = MimeMessage()..body = _leaf('text/plain');
      expect(ImapDatasourceImpl.collectAttachments(msg), isEmpty);
    });

    test('finds an attachment declared with Content-Disposition: attachment',
        () {
      final msg = _multipart('mixed', [
        _leaf('text/plain'),
        _leaf('application/pdf',
            disposition: 'attachment',
            dispositionFilename: 'report.pdf',
            size: 2048),
      ]);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments, hasLength(1));
      expect(attachments.single.id, '2'); // IMAP part number for getPart
      expect(attachments.single.name, 'report.pdf');
      expect(attachments.single.contentType, 'application/pdf');
      expect(attachments.single.size, 2048);
    });

    test(
        'finds an attachment declared only via Content-Type name, no disposition',
        () {
      // The regression this fix targets: enough_mail's disposition-only
      // findContentInfo/hasAttachments miss this part entirely.
      final msg = _multipart('mixed', [
        _leaf('text/html'),
        _leaf('application/octet-stream', name: 'data.bin'),
      ]);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments, hasLength(1));
      expect(attachments.single.name, 'data.bin');
      expect(attachments.single.id, '2');
    });

    test('reads the filename case-insensitively (server sent NAME/FILENAME)',
        () {
      // BODYSTRUCTURE parameter names arrive in whatever case the server
      // used; enough_mail stores them verbatim, so a naive params['name']
      // lookup would miss these.
      final msg = _multipart('mixed', [
        _leaf('text/plain'),
        _leaf('application/pdf',
            disposition: 'attachment',
            dispositionFilenameParam: 'FILENAME',
            dispositionFilename: 'caps.pdf'),
        _leaf('application/zip', nameParam: 'NAME', name: 'archive.zip'),
      ]);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments.map((a) => a.name),
          containsAll(<String>['caps.pdf', 'archive.zip']));
    });

    test('strips surrounding quotes left on a BODYSTRUCTURE filename', () {
      final msg = _multipart('mixed', [
        _leaf('text/plain'),
        _leaf('application/pdf',
            disposition: 'attachment', dispositionFilename: '"quoted.pdf"'),
      ]);

      expect(
          ImapDatasourceImpl.collectAttachments(msg).single.name, 'quoted.pdf');
    });

    test('falls back to a generic name when the part has no filename', () {
      final msg = _multipart('mixed', [
        _leaf('text/plain'),
        _leaf('application/pdf', disposition: 'attachment'),
      ]);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments, hasLength(1));
      expect(attachments.single.name, 'Attachment');
    });

    test('ignores inline (cid) images even when they carry a filename', () {
      final msg = _multipart('related', [
        _leaf('text/html'),
        _leaf('image/png',
            disposition: 'inline',
            dispositionFilename: 'logo.png',
            cid: '<logo@x>'),
      ]);

      expect(ImapDatasourceImpl.collectAttachments(msg), isEmpty);
    });

    test('ignores a part that only has a Content-Id and no disposition', () {
      final msg = _multipart('related', [
        _leaf('text/html'),
        _leaf('image/png', name: 'logo.png', cid: '<logo@x>'),
      ]);

      expect(ImapDatasourceImpl.collectAttachments(msg), isEmpty);
    });

    test('mixes a real attachment with an inline image', () {
      final msg = _multipart('mixed', [
        _multipart('related', [
          _leaf('text/html'),
          _leaf('image/png', disposition: 'inline', cid: '<logo@x>'),
        ]).body!,
        _leaf('application/pdf',
            disposition: 'attachment', dispositionFilename: 'invoice.pdf'),
      ]);

      final attachments = ImapDatasourceImpl.collectAttachments(msg);

      expect(attachments, hasLength(1));
      expect(attachments.single.name, 'invoice.pdf');
      expect(attachments.single.id, '2'); // second top-level part
    });
  });

  group('ImapDatasourceImpl connection serialisation', () {
    ImapDatasourceImpl build() => ImapDatasourceImpl(
          account: _account,
          credentialStorage: _NoPasswordStorage(),
        );

    test('runs one body at a time, in the order they were queued', () async {
      final ds = build();
      final order = <String>[];

      Future<void> slowBody(String name, int hops) async {
        order.add('$name-start');
        for (var i = 0; i < hops; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        order.add('$name-end');
      }

      // The first body yields repeatedly: without the chain its awaits are
      // exactly where the second body would interleave — which on a real
      // connection is a SELECT landing between another caller's SELECT and
      // its FETCH.
      final first = ds.withConnection(() => slowBody('a', 3));
      final second = ds.withConnection(() => slowBody('b', 1));
      await Future.wait([first, second]);

      expect(order, ['a-start', 'a-end', 'b-start', 'b-end']);
    });

    test('a body that throws does not wedge the callers behind it', () async {
      final ds = build();

      final failed = ds.withConnection<void>(
        () async => throw StateError('boom'),
      );
      await expectLater(failed, throwsA(isA<StateError>()));

      expect(await ds.withConnection(() async => 'ran'), 'ran');
    });

    test('a failed connect is retried rather than awaited forever', () async {
      final ds = build();

      // No stored password → AuthException from inside the chained link. The
      // second call must reach the connect attempt again: _connectingFuture is
      // cleared in a `finally`, so a stalled or abandoned connect cannot be
      // handed to every later caller for the process lifetime.
      await expectLater(
        ds.getEmails(folderId: 'INBOX'),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        ds.getEmails(folderId: 'INBOX'),
        throwsA(isA<AuthException>()),
      );
    });

    test('an IDLE watch that cannot connect stops instead of blocking reads',
        () async {
      final ds = build();

      ds.startIdleWatch('INBOX');
      // The watch's own link fails at the connect, which ends the watch — a
      // half-wired IDLE holding the connection would starve this caller.
      expect(
        await ds.withConnection(() async => 'ran').timeout(
              const Duration(seconds: 5),
            ),
        'ran',
      );
      ds.stopIdleWatch();
    });
  });

  group('ImapFolderStatus', () {
    const base = ImapFolderStatus(
      messages: 10,
      unseen: 2,
      uidNext: 100,
      uidValidity: 7,
    );

    test('a read plus an arrival is a change, though both counts hold', () {
      // The case two counts cannot see: one message read (unseen 2 → 1) and one
      // new one arrived (unseen 1 → 2, messages 10 → 11... and one expunged).
      const next = ImapFolderStatus(
        messages: 10,
        unseen: 2,
        uidNext: 101,
        uidValidity: 7,
      );

      expect(next.differsFrom(base), isTrue);
    });

    test('an unchanged mailbox reports no change', () {
      expect(base.differsFrom(base), isFalse);
      expect(base.wasRebuiltSince(base), isFalse);
    });

    test('a new UIDVALIDITY means every cached uid is meaningless', () {
      const rebuilt = ImapFolderStatus(
        messages: 10,
        unseen: 2,
        uidNext: 100,
        uidValidity: 8,
      );

      expect(rebuilt.wasRebuiltSince(base), isTrue);
    });

    test('a server that reports no UIDVALIDITY never claims a rebuild', () {
      const noValidity = ImapFolderStatus(messages: 10, unseen: 2, uidNext: 100);

      expect(noValidity.wasRebuiltSince(base), isFalse);
      expect(base.wasRebuiltSince(noValidity), isFalse);
    });
  });
}

const _account = ImapAccount(
  id: 'acct-1',
  displayName: 'Test',
  emailAddress: 'test@example.com',
  host: 'imap.example.com',
  port: 993,
  useSsl: true,
  smtpHost: 'smtp.example.com',
  smtpPort: 587,
  smtpUseSsl: false,
);

/// Stands in for the keychain with nothing in it, so every connect attempt
/// fails before a socket is opened — these tests never touch the network.
class _NoPasswordStorage extends ImapCredentialStorage {
  _NoPasswordStorage() : super(const FlutterSecureStorage());

  @override
  Future<String?> loadPassword(String accountId) async => null;
}
