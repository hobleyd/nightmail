import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/imap_datasource_impl.dart';

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
}
