import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/error/exceptions.dart';
import '../../../core/utils/html_entities.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/email_attachment.dart';
import '../../../domain/entities/inline_attachment.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../infrastructure/auth/imap_credential_storage.dart';
import '../../models/email_address_model.dart';
import '../../models/email_folder_model.dart';
import '../../models/email_model.dart';
import 'email_remote_datasource.dart';

class ImapDatasourceImpl implements EmailRemoteDatasource {
  ImapDatasourceImpl({
    required this._account,
    required this._credentialStorage,
  });

  final ImapAccount _account;
  final ImapCredentialStorage _credentialStorage;

  ImapClient? _client;
  String? _selectedMailboxPath;

  /// Non-empty when the server uses abbreviated folder names that must be
  /// prefixed (e.g. Courier IMAP returns "Sent" in LIST but requires
  /// SELECT "INBOX.Sent"). Set once in [getMailFolders] and reused thereafter.
  String _inboxFolderPrefix = '';

  /// Path separator reported by the server (e.g. '/' for Gmail, '.' for Courier).
  /// Set in [getMailFolders] and reused in [getChildFolders].
  String _pathSeparator = '.';

  /// Derives the path separator and inbox folder prefix from [rootMailboxes].
  ///
  /// Abbreviated namespace: Courier and some Dovecot configs advertise root
  /// folders (Sent, Drafts, Trash) that are actually children of INBOX and
  /// must be accessed as INBOX<sep>Sent, INBOX<sep>Drafts, etc.
  ///
  /// Detection strategy:
  /// - Courier always uses '.'; abbreviated-namespace detection always runs.
  /// - For '/' (and other separators), run detection only when INBOX reports
  ///   \HasChildren — real abbreviated-namespace servers have INBOX children,
  ///   while Gmail labels at root level don't give INBOX any children.
  @visibleForTesting
  static ({String pathSeparator, String inboxFolderPrefix})
      detectNamespaceConvention(List<Mailbox> rootMailboxes) {
    final sep = rootMailboxes.firstOrNull?.pathSeparator ?? '.';
    final inboxMailbox = rootMailboxes
        .where((mb) => mb.path.toUpperCase() == 'INBOX')
        .firstOrNull;

    String prefix = '';
    if (inboxMailbox != null) {
      final hasExplicitInboxChildren = rootMailboxes.any(
        (mb) => mb.path.toUpperCase().startsWith('INBOX$sep'),
      );
      final hasAbbreviatedRoots = rootMailboxes.any(
        (mb) =>
            mb.path.toUpperCase() != 'INBOX' &&
            !mb.path.contains(sep) &&
            !mb.isNotSelectable,
      );
      // For Courier (sep='.'), abbreviated namespace is always used.
      // For other separators (e.g. '/'), require \HasChildren on INBOX:
      // Gmail labels appear as root folders but INBOX has no children, whereas
      // Dovecot abbreviated-namespace servers do report \HasChildren on INBOX.
      final runDetection = sep == '.' || inboxMailbox.hasChildren;
      prefix = (!hasExplicitInboxChildren && hasAbbreviatedRoots && runDetection)
          ? 'INBOX$sep'
          : '';
    }

    return (pathSeparator: sep, inboxFolderPrefix: prefix);
  }

  Future<ImapClient> _getConnectedClient() async {
    if (_client != null && _client!.isConnected) return _client!;

    final password = await _credentialStorage.loadPassword(_account.id);
    if (password == null) {
      throw const AuthException(message: 'No IMAP credentials stored');
    }

    final client = ImapClient(isLogEnabled: true);
    await client.connectToServer(
      _account.host,
      _account.port,
      isSecure: _account.useSsl,
    );
    await client.login(_account.emailAddress, password);
    _client = client;
    _selectedMailboxPath = null;
    return client;
  }

  /// SELECT the mailbox at [path].
  ///
  /// On servers that use abbreviated folder names in LIST but require the
  /// full INBOX-prefixed path in SELECT (Courier IMAP, some Dovecot configs),
  /// the first attempt will fail. We retry unconditionally with the INBOX
  /// prefix and cache the result so [getMailFolders] can normalise IDs on the
  /// next call.
  Future<void> _selectMailboxPath(ImapClient client, String path) async {
    if (_selectedMailboxPath == path) return;
    try {
      await client.selectMailboxByPath(path);
      _selectedMailboxPath = path;
    } on ImapException catch (first) {
      if (path.toUpperCase().startsWith('INBOX')) {
        // Already prefixed — nothing more we can do.
        throw ServerException(message: first.message ?? 'IMAP error');
      }
      // Try with INBOX prefix. If this also fails, surface the original error.
      try {
        final sep = _inboxFolderPrefix.isNotEmpty
            ? _inboxFolderPrefix.replaceAll('INBOX', '')
            : _pathSeparator;
        final prefixed = 'INBOX$sep$path';
        await client.selectMailboxByPath(prefixed);
        _selectedMailboxPath = prefixed;
        // Cache so getMailFolders() normalises IDs on the next refresh.
        _inboxFolderPrefix = 'INBOX$sep';
      } on ImapException {
        throw ServerException(message: first.message ?? 'IMAP error');
      }
    }
  }

  /// Issues STATUS (MESSAGES UNSEEN) for each selectable mailbox, mutating
  /// [mb.messagesExists] and [mb.messagesUnseen] in-place. Used on servers
  /// that don't support the LIST-STATUS extension (RFC 5819).
  Future<void> _fetchStatusForMailboxes(
    ImapClient client,
    List<Mailbox> mailboxes,
  ) async {
    for (final mb in mailboxes) {
      if (mb.isNotSelectable) continue;
      try {
        await client.statusMailbox(
          mb,
          [StatusFlags.messages, StatusFlags.unseen],
        );
      } on ImapException {
        // Ignore — some virtual/special mailboxes reject STATUS.
      }
    }
  }

  @override
  Future<List<EmailFolderModel>> getMailFolders() async {
    try {
      final client = await _getConnectedClient();

      // List only the root-level mailboxes (LIST "" %).
      // The EmailRepository expansion loop will call getChildFolders() for
      // folders with children — this avoids the duplicate-folder problem that
      // would occur if we returned the full recursive list here while the repo
      // also tries to expand children on top of it.
      final supportsListStatus = client.serverInfo.supports('LIST-STATUS');
      final supportsChildren = client.serverInfo.supports('CHILDREN');
      final rootMailboxes = await client.listMailboxes(
        recursive: false,
        returnOptions: supportsListStatus
            ? [
                ReturnOption.status(['MESSAGES', 'UNSEEN']),
                if (supportsChildren) ReturnOption.children(),
              ]
            : null,
      );
      if (!supportsListStatus) {
        await _fetchStatusForMailboxes(client, rootMailboxes);
      }

      final convention = detectNamespaceConvention(rootMailboxes);
      _pathSeparator = convention.pathSeparator;
      _inboxFolderPrefix = convention.inboxFolderPrefix;

      return rootMailboxes.map((mb) {
        // Normalise path for servers that use abbreviated naming (Courier IMAP).
        final fullPath =
            (_inboxFolderPrefix.isNotEmpty &&
                    !mb.path.toUpperCase().startsWith('INBOX'))
                ? '$_inboxFolderPrefix${mb.path}'
                : mb.path;

        // Derive parent from the full path so prefixed folders (e.g. Courier's
        // "Sent" → "INBOX.Sent") get parentFolderId = "INBOX" not null.
        final parts = fullPath.split(_pathSeparator);
        final parentPath =
            parts.length > 1 ? parts.sublist(0, parts.length - 1).join(_pathSeparator) : null;

        return EmailFolderModel(
          id: fullPath,
          displayName: mb.name,
          totalItemCount: mb.messagesExists,
          unreadItemCount: mb.messagesUnseen,
          parentFolderId: parentPath,
          isHidden: mb.isNotSelectable,
          childFolderCount: mb.hasChildren ? 1 : 0,
        );
      }).toList();
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    } on AuthException {
      rethrow;
    }
  }

  @override
  Future<List<EmailFolderModel>> getChildFolders(String parentFolderId) async {
    try {
      final client = await _getConnectedClient();

      // LIST "parent<sep>" % lists direct children.
      // Using the reference with a trailing separator is the standard portable
      // approach — LIST "INBOX" % returns INBOX itself on many servers.
      final sep = _pathSeparator;
      final supportsListStatus = client.serverInfo.supports('LIST-STATUS');
      final supportsChildren = client.serverInfo.supports('CHILDREN');
      final mailboxes = await client.listMailboxes(
        path: '"$parentFolderId$sep"',
        recursive: false,
        returnOptions: supportsListStatus
            ? [
                ReturnOption.status(['MESSAGES', 'UNSEEN']),
                if (supportsChildren) ReturnOption.children(),
              ]
            : null,
      );
      if (!supportsListStatus) {
        await _fetchStatusForMailboxes(client, mailboxes);
      }

      return mailboxes.map((mb) {
        // Derive the actual parent from the child's full path.
        final parts = mb.path.split(sep);
        final parentPath = parts.length > 1
            ? parts.sublist(0, parts.length - 1).join(sep)
            : null;

        return EmailFolderModel(
          id: mb.path,
          displayName: mb.name,
          totalItemCount: mb.messagesExists,
          unreadItemCount: mb.messagesUnseen,
          parentFolderId: parentPath,
          isHidden: mb.isNotSelectable,
          childFolderCount: mb.hasChildren ? 1 : 0,
        );
      }).toList();
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  @override
  Future<List<EmailModel>> getEmails({
    String? folderId,
    int top = 25,
    int skip = 0,
    String? filter,
    String orderBy = 'receivedDateTime desc',
  }) async {
    final mailboxPath = folderId ?? 'INBOX';
    try {
      final client = await _getConnectedClient();
      await _selectMailboxPath(client, mailboxPath);

      // UID SEARCH returns UIDs directly; plain SEARCH returns sequence numbers.
      final searchResult = await client.uidSearchMessages(
        searchCriteria: 'ALL',
      );
      final allUids = searchResult.matchingSequence?.toList() ?? [];
      if (allUids.isEmpty) return [];

      // Most recent first (IMAP UID sequences are ascending).
      final reversed = allUids.reversed.toList();
      final page = reversed.skip(skip).take(top).toList();
      if (page.isEmpty) return [];

      final sequence = MessageSequence.fromIds(page, isUid: true);
      final fetchResult = await client.uidFetchMessages(
        sequence,
        '(FLAGS INTERNALDATE ENVELOPE)',
      );

      return fetchResult.messages
          .map((msg) => _parseToModel(msg, folderId: _selectedMailboxPath ?? mailboxPath))
          .toList();
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    } on AuthException {
      rethrow;
    }
  }

  @override
  Future<List<EmailModel>> searchEmails({
    String? folderId,
    required String query,
    int top = 50,
  }) async {
    final mailboxPath = folderId ?? 'INBOX';
    try {
      final client = await _getConnectedClient();
      await _selectMailboxPath(client, mailboxPath);

      final criteria = _buildImapCriteria(query);
      final searchResult =
          await client.uidSearchMessages(searchCriteria: criteria);
      final allUids = searchResult.matchingSequence?.toList() ?? [];
      if (allUids.isEmpty) return [];

      final page = allUids.reversed.take(top).toList();
      final sequence = MessageSequence.fromIds(page, isUid: true);
      final fetchResult = await client.uidFetchMessages(
        sequence,
        '(FLAGS INTERNALDATE ENVELOPE)',
      );

      return fetchResult.messages
          .map((msg) =>
              _parseToModel(msg, folderId: _selectedMailboxPath ?? mailboxPath))
          .toList();
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    } on AuthException {
      rethrow;
    }
  }

  String _buildImapCriteria(String query) {
    final criteria = <String>[];
    var remaining = query.trim();

    // Extract field:value tokens.
    final tokenRe = RegExp(r'(\w+):(\S+)', caseSensitive: false);
    for (final m in tokenRe.allMatches(query)) {
      remaining = remaining.replaceFirst(m.group(0)!, '').trim();
      final field = m.group(1)!.toLowerCase();
      final value = m.group(2)!;
      switch (field) {
        case 'from':
          criteria.add('FROM "$value"');
        case 'to':
          criteria.add('TO "$value"');
        case 'subject':
          criteria.add('SUBJECT "$value"');
        // has:attachment not supported by basic IMAP SEARCH; skip silently.
      }
    }

    if (remaining.isNotEmpty) {
      criteria.add('TEXT "$remaining"');
    }

    return criteria.isEmpty ? 'ALL' : criteria.join(' ');
  }

  @override
  Future<EmailModel> getEmail(String id) async {
    // id format: "mailboxPath:uid"
    final separatorIdx = id.lastIndexOf(':');
    final mailboxPath =
        separatorIdx > 0 ? id.substring(0, separatorIdx) : 'INBOX';
    final uid = int.tryParse(id.substring(separatorIdx + 1)) ?? 0;

    try {
      final client = await _getConnectedClient();
      await _selectMailboxPath(client, mailboxPath);

      final sequence = MessageSequence.fromId(uid, isUid: true);
      final fetchResult = await client.uidFetchMessages(
        sequence,
        '(FLAGS INTERNALDATE ENVELOPE BODY[])',
      );

      if (fetchResult.messages.isEmpty) {
        throw ServerException(message: 'Message not found: $id');
      }

      return _parseToModel(
        fetchResult.messages.first,
        folderId: _selectedMailboxPath ?? mailboxPath,
        fullBody: true,
      );
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    } on AuthException {
      rethrow;
    }
  }

  @override
  Future<EmailModel> updateEmailReadStatus({
    required String id,
    required bool isRead,
  }) async {
    final separatorIdx = id.lastIndexOf(':');
    final mailboxPath =
        separatorIdx > 0 ? id.substring(0, separatorIdx) : 'INBOX';
    final uid = int.tryParse(id.substring(separatorIdx + 1)) ?? 0;

    try {
      final client = await _getConnectedClient();
      await _selectMailboxPath(client, mailboxPath);

      final sequence = MessageSequence.fromId(uid, isUid: true);
      await client.uidStore(
        sequence,
        [MessageFlags.seen],
        action: isRead ? StoreAction.add : StoreAction.remove,
      );

      return getEmail(id);
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  @override
  Future<Uint8List> getRawEmailBytes(String id) async {
    final separatorIdx = id.lastIndexOf(':');
    final mailboxPath =
        separatorIdx > 0 ? id.substring(0, separatorIdx) : 'INBOX';
    final uid = int.tryParse(id.substring(separatorIdx + 1)) ?? 0;

    try {
      final client = await _getConnectedClient();
      await _selectMailboxPath(client, mailboxPath);

      final sequence = MessageSequence.fromId(uid, isUid: true);
      final fetchResult = await client.uidFetchMessages(
        sequence,
        'BODY.PEEK[]',
      );

      if (fetchResult.messages.isEmpty) {
        throw ServerException(message: 'Message not found: $id');
      }

      final buffer = StringBuffer();
      fetchResult.messages.first.render(buffer);
      return Uint8List.fromList(buffer.toString().codeUnits);
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    } on AuthException {
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Parsing
  // ---------------------------------------------------------------------------

  EmailModel _parseToModel(
    MimeMessage msg, {
    required String folderId,
    bool fullBody = false,
  }) {
    final uid = msg.uid ?? msg.sequenceId ?? 0;
    final id = '$folderId:$uid';
    final isRead = msg.isSeen;
    final date = msg.decodeDate() ?? DateTime.now().toUtc();

    String body = '';
    EmailBodyType bodyType = EmailBodyType.text;

    List<EmailAttachment> attachments = const [];
    List<InlineAttachment> inlineAttachments = const [];

    if (fullBody) {
      final html = msg.decodeTextHtmlPart();
      if (html != null && html.isNotEmpty) {
        body = html;
        bodyType = EmailBodyType.html;
      } else {
        final plain = msg.decodeTextPlainPart();
        body = plain ?? '';
      }

      attachments = msg
          .findContentInfo(disposition: ContentDisposition.attachment)
          .map((info) => EmailAttachment(
                id: info.fetchId,
                name: info.fileName ?? 'Attachment',
                contentType:
                    info.contentType?.mediaType.text ?? 'application/octet-stream',
                size: info.size ?? 0,
              ))
          .toList();

      final inlineResult = <InlineAttachment>[];
      for (final info
          in msg.findContentInfo(disposition: ContentDisposition.inline)) {
        if (info.isText) continue;
        final cid = info.cid;
        if (cid == null || cid.isEmpty) continue;
        final bytes = msg.getPart(info.fetchId)?.decodeContentBinary();
        if (bytes == null) continue;
        inlineResult.add(InlineAttachment(
          contentId: cid,
          contentType:
              info.contentType?.mediaType.text ?? 'application/octet-stream',
          contentBytes: bytes,
        ));
      }
      inlineAttachments = inlineResult;
    }

    final fromAddresses = msg.from;
    final from = fromAddresses?.firstOrNull;
    final fromModel = from != null
        ? EmailAddressModel(
            address: from.email,
            name: from.personalName ?? '',
          )
        : const EmailAddressModel(address: '', name: '');

    List<EmailAddressModel> mapAddresses(List<MailAddress>? list) {
      return (list ?? [])
          .map((a) => EmailAddressModel(
                address: a.email,
                name: a.personalName ?? '',
              ))
          .toList();
    }

    final preview = msg.decodeTextPlainPart() ?? '';
    final bodyPreview =
        preview.length > 200 ? preview.substring(0, 200) : preview;

    return EmailModel(
      id: id,
      subject: decodeHtmlEntities(msg.decodeSubject() ?? '(No Subject)'),
      from: fromModel,
      toRecipients: mapAddresses(msg.to),
      ccRecipients: mapAddresses(msg.cc),
      bodyPreview: bodyPreview,
      body: body,
      bodyType: bodyType,
      isRead: isRead,
      receivedDateTime: date,
      importance: EmailImportance.normal,
      conversationId: _normalizeSubject(msg.decodeSubject() ?? ''),
      parentFolderId: folderId,
      hasAttachments: msg.hasAttachments(),
      attachments: attachments,
      inlineAttachments: inlineAttachments,
    );
  }

  /// Returns a stable conversation key by stripping reply/forward prefixes.
  /// All messages in a thread share the same normalized subject, so this
  /// correctly groups threads without relying on Message-ID chains.
  static String? _normalizeSubject(String subject) {
    var s = subject.trim();
    if (s.isEmpty) return null;
    final prefix = RegExp(
      r'^(Re|Fwd|Fw|Aw|Sv|Ref)\s*(\[\d+\])?\s*:\s*',
      caseSensitive: false,
    );
    while (prefix.hasMatch(s)) {
      s = s.replaceFirst(prefix, '').trim();
    }
    final normalized = s.toLowerCase();
    return normalized.isEmpty ? null : normalized;
  }

  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    _selectedMailboxPath = null;
    if (client == null || !client.isConnected) return;
    try {
      await client.logout();
    } catch (_) {}
    try {
      await client.disconnect();
    } catch (_) {}
  }

  Future<SmtpClient> _getSmtpClient() async {
    final password = await _credentialStorage.loadPassword(_account.id);
    if (password == null) {
      throw const AuthException(message: 'No SMTP credentials stored');
    }

    final client = SmtpClient('nightmail', isLogEnabled: false);
    await client.connectToServer(
      _account.smtpHost,
      _account.smtpPort,
      isSecure: _account.smtpUseSsl,
    );
    await client.ehlo();
    if (!_account.smtpUseSsl && client.serverInfo.supportsStartTls) {
      await client.startTls();
    }
    await client.authenticate(_account.emailAddress, password);
    return client;
  }

  Future<void> _sendMime(MimeMessage message) async {
    final client = await _getSmtpClient();
    try {
      final response = await client.sendMessage(message);
      if (!response.isOkStatus) {
        throw ServerException(message: 'SMTP error: ${response.code}');
      }
    } on SmtpException catch (e) {
      throw ServerException(message: e.message ?? 'SMTP error');
    } finally {
      await client.quit();
    }
  }

  @override
  Future<void> sendEmail({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
  }) async {
    final builder = MessageBuilder()
      ..from = [MailAddress(_account.displayName, _account.emailAddress)]
      ..to = toAddresses.map((e) => MailAddress(null, e)).toList()
      ..cc = ccAddresses.map((e) => MailAddress(null, e)).toList()
      ..subject = subject
      ..addTextPlain(body);
    await _sendMime(builder.buildMimeMessage());
  }

  /// Splits a composite message ID (`folderId:uid`) into its parts.
  /// Returns null if the ID is malformed.
  (String folderId, int uid)? _parseMessageId(String messageId) {
    final sep = messageId.lastIndexOf(':');
    if (sep <= 0) return null;
    final uid = int.tryParse(messageId.substring(sep + 1));
    if (uid == null) return null;
    return (messageId.substring(0, sep), uid);
  }

  Future<MimeMessage> _fetchOriginal(String messageId) async {
    final parsed = _parseMessageId(messageId);
    if (parsed == null) throw ServerException(message: 'Invalid message ID');
    final (folderId, uid) = parsed;

    final client = await _getConnectedClient();
    try {
      await _selectMailboxPath(client, folderId);
      final seq = MessageSequence.fromId(uid, isUid: true);
      final result = await client.uidFetchMessages(seq, 'BODY.PEEK[]');
      final msg = result.messages.firstOrNull;
      if (msg == null) throw ServerException(message: 'Message not found');
      return msg;
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  @override
  Future<void> replyToEmail({
    required String messageId,
    required String comment,
    bool replyAll = false,
    EmailBodyType bodyType = EmailBodyType.text,
  }) async {
    final original = await _fetchOriginal(messageId);
    final builder = MessageBuilder.prepareReplyToMessage(
      original,
      MailAddress(_account.displayName, _account.emailAddress),
      replyAll: replyAll,
    );
    if (bodyType == EmailBodyType.html) {
      builder.addTextHtml(comment);
    } else {
      builder.addTextPlain(comment);
    }
    await _sendMime(builder.buildMimeMessage());
  }

  @override
  Future<void> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    required String comment,
    List<String> excludedAttachmentIds = const [],
    EmailBodyType bodyType = EmailBodyType.text,
  }) async {
    final original = await _fetchOriginal(messageId);

    final builder = MessageBuilder.prepareForwardMessage(
      original,
      from: MailAddress(_account.displayName, _account.emailAddress),
    )..to = toAddresses.map((e) => MailAddress(null, e)).toList();
    if (bodyType == EmailBodyType.html) {
      builder.addTextHtml(comment);
    } else {
      builder.addTextPlain(comment);
    }
    await _sendMime(builder.buildMimeMessage());
  }

  @override
  Future<void> moveEmail(String id, String destinationFolderId) async {
    final separatorIdx = id.lastIndexOf(':');
    final mailboxPath =
        separatorIdx > 0 ? id.substring(0, separatorIdx) : 'INBOX';
    final uid = int.tryParse(id.substring(separatorIdx + 1)) ?? 0;

    try {
      final client = await _getConnectedClient();
      await _selectMailboxPath(client, mailboxPath);

      final sequence = MessageSequence.fromId(uid, isUid: true);
      await client.uidCopy(sequence, targetMailboxPath: destinationFolderId);
      await client.uidStore(
        sequence,
        [MessageFlags.deleted],
        action: StoreAction.add,
      );
      await client.expunge();
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  @override
  Future<void> reportJunk(String id) async {
    final separatorIdx = id.lastIndexOf(':');
    final mailboxPath =
        separatorIdx > 0 ? id.substring(0, separatorIdx) : 'INBOX';
    final uid = int.tryParse(id.substring(separatorIdx + 1)) ?? 0;

    try {
      final client = await _getConnectedClient();
      final junkPath = await _findJunkPath(client);
      await _selectMailboxPath(client, mailboxPath);
      final sequence = MessageSequence.fromId(uid, isUid: true);
      if (junkPath != null) {
        try {
          await client.uidCopy(sequence, targetMailboxPath: junkPath);
        } on ImapException {
          // Copy failed (e.g. folder inaccessible or wrong path encoding).
          // Fall through to delete from source so the message doesn't linger
          // in the inbox and cause confusing reappearance on folder switch.
        }
      }
      await client.uidStore(
        sequence,
        [MessageFlags.deleted],
        action: StoreAction.add,
      );
      await client.expunge();
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  Future<String?> _findJunkPath(ImapClient client) async {
    try {
      final mailboxes = await client.listMailboxes(recursive: true);
      final junkMailbox = mailboxes.where((mb) => mb.isJunk).firstOrNull ??
          _wellKnownJunkMailbox(mailboxes);
      if (junkMailbox == null) return null;
      // Normalize abbreviated path to full path, matching getMailFolders logic.
      // On INBOX-prefixed servers (Courier/Dovecot), LIST returns 'Junk' but
      // UID COPY requires the full path 'INBOX.Junk'.
      return (_inboxFolderPrefix.isNotEmpty &&
              !junkMailbox.path.toUpperCase().startsWith('INBOX'))
          ? '$_inboxFolderPrefix${junkMailbox.path}'
          : junkMailbox.path;
    } on ImapException {
      return null;
    }
  }

  Mailbox? _wellKnownJunkMailbox(List<Mailbox> mailboxes) {
    const wellKnown = ['Junk', 'Junk Email', 'Spam', 'Bulk Mail'];
    for (final name in wellKnown) {
      final fullName =
          _inboxFolderPrefix.isNotEmpty ? '$_inboxFolderPrefix$name' : name;
      final match = mailboxes
          .where(
            (mb) =>
                mb.path.toLowerCase() == fullName.toLowerCase() ||
                mb.path.toLowerCase() == name.toLowerCase(),
          )
          .firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  @override
  Future<void> deleteEmail(String id) async {
    final separatorIdx = id.lastIndexOf(':');
    final mailboxPath =
        separatorIdx > 0 ? id.substring(0, separatorIdx) : 'INBOX';
    final uid = int.tryParse(id.substring(separatorIdx + 1)) ?? 0;

    try {
      final client = await _getConnectedClient();

      // Resolve the trash folder before selecting the source mailbox so that
      // the LIST command cannot interfere with the server-side mailbox selection.
      final trashPath = await _findTrashPath(client, currentPath: mailboxPath);

      // Select source mailbox after the LIST so it remains selected for COPY,
      // STORE, and EXPUNGE.
      await _selectMailboxPath(client, mailboxPath);

      final sequence = MessageSequence.fromId(uid, isUid: true);

      if (trashPath != null) {
        // Move to Trash: copy to the Trash folder first.
        await client.uidCopy(sequence, targetMailboxPath: trashPath);
      }

      // Mark \Deleted and expunge to remove from the source mailbox.
      await client.uidStore(
        sequence,
        [MessageFlags.deleted],
        action: StoreAction.add,
      );
      await client.expunge();
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  @override
  Future<void> emptyFolder(String folderId,
      {bool permanentDelete = false}) async {
    final mailboxPath = folderId;
    try {
      final client = await _getConnectedClient();

      String? trashPath;
      if (!permanentDelete) {
        // Resolve trash before SELECT so LIST doesn't interfere with the
        // subsequent mailbox selection.
        trashPath = await _findTrashPath(client, currentPath: mailboxPath);
      }

      // All subsequent IMAP commands (SEARCH, UID COPY, UID STORE, EXPUNGE)
      // are scoped to the selected mailbox only — subfolders are separate
      // mailboxes and are completely unaffected by these operations.
      await _selectMailboxPath(client, mailboxPath);

      final searchResult =
          await client.uidSearchMessages(searchCriteria: 'ALL');
      final allUids = searchResult.matchingSequence?.toList() ?? [];
      if (allUids.isEmpty) return;

      final sequence = MessageSequence.fromIds(allUids, isUid: true);

      if (!permanentDelete && trashPath != null) {
        await client.uidCopy(sequence, targetMailboxPath: trashPath);
      }

      await client.uidStore(
        sequence,
        [MessageFlags.deleted],
        action: StoreAction.add,
      );
      await client.expunge();
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  @override
  Future<void> createFolder({
    required String parentFolderId,
    required String displayName,
  }) async {
    try {
      final client = await _getConnectedClient();
      // _pathSeparator is set by getMailFolders; folders are always listed before
      // any create action is triggered from the UI so this will be populated.
      final newPath = '$parentFolderId$_pathSeparator$displayName';
      await client.createMailbox(newPath);
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  /// Returns the path of the Trash mailbox, or null if the message is already
  /// in Trash or no Trash folder can be located on this server.
  Future<String?> _findTrashPath(
    ImapClient client, {
    required String currentPath,
  }) async {
    try {
      final mailboxes = await client.listMailboxes(recursive: true);

      // Prefer \Trash special-use attribute (RFC 6154); fall back to names.
      final trashMailbox =
          mailboxes.where((mb) => mb.isTrash).firstOrNull ??
              _wellKnownTrashMailbox(mailboxes);

      if (trashMailbox == null) return null;

      // Normalize abbreviated path to full path, matching getMailFolders logic.
      final trashPath = (_inboxFolderPrefix.isNotEmpty &&
              !trashMailbox.path.toUpperCase().startsWith('INBOX'))
          ? '$_inboxFolderPrefix${trashMailbox.path}'
          : trashMailbox.path;

      // Already in Trash — skip the copy and just expunge permanently.
      if (trashPath.toLowerCase() == currentPath.toLowerCase()) {
        return null;
      }
      return trashPath;
    } on ImapException {
      return null;
    }
  }

  Mailbox? _wellKnownTrashMailbox(List<Mailbox> mailboxes) {
    const wellKnown = ['Trash', 'Deleted Items', 'Deleted Messages'];
    for (final name in wellKnown) {
      final fullName =
          _inboxFolderPrefix.isNotEmpty ? '$_inboxFolderPrefix$name' : name;
      final match = mailboxes
          .where(
            (mb) =>
                mb.path.toLowerCase() == fullName.toLowerCase() ||
                mb.path.toLowerCase() == name.toLowerCase(),
          )
          .firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  @override
  Future<Uint8List> downloadAttachment(
      String messageId, String attachmentId) async {
    final separatorIdx = messageId.lastIndexOf(':');
    final mailboxPath =
        separatorIdx > 0 ? messageId.substring(0, separatorIdx) : 'INBOX';
    final uid = int.tryParse(messageId.substring(separatorIdx + 1)) ?? 0;

    try {
      final client = await _getConnectedClient();
      await _selectMailboxPath(client, mailboxPath);

      final sequence = MessageSequence.fromId(uid, isUid: true);
      final fetchResult = await client.uidFetchMessages(
        sequence,
        'BODY.PEEK[]',
      );

      if (fetchResult.messages.isEmpty) {
        throw ServerException(message: 'Message not found: $messageId');
      }

      final part = fetchResult.messages.first.getPart(attachmentId);
      if (part == null) {
        throw ServerException(message: 'Attachment not found: $attachmentId');
      }

      final bytes = part.decodeContentBinary();
      if (bytes == null) {
        throw ServerException(
            message: 'Could not decode attachment: $attachmentId');
      }
      return bytes;
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    } on AuthException {
      rethrow;
    }
  }
}
