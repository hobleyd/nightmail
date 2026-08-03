import 'dart:io' show SocketException, TlsException;
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import '../../../core/error/exceptions.dart';
import '../../../core/utils/html_entities.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/local_attachment.dart';
import '../../../domain/entities/email_attachment.dart';
import '../../../domain/entities/inline_attachment.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../infrastructure/auth/imap_credential_storage.dart';
import '../../models/email_address_model.dart';
import '../../models/email_folder_model.dart';
import '../../models/email_model.dart';
import 'email_remote_datasource.dart';
import 'spam_db_sync_datasource.dart';

const _spamDbFolderName = 'SPAMDB';
const _spamDbVersionHeader = 'X-NightMail-SpamDb-Version';

class ImapDatasourceImpl
    implements EmailRemoteDatasource, SpamDbSyncDatasource {
  ImapDatasourceImpl({
    required this._account,
    required this._credentialStorage,
  });

  final ImapAccount _account;
  final ImapCredentialStorage _credentialStorage;

  /// Ceiling on the whole SMTP connect → EHLO → STARTTLS → AUTH exchange.
  static const _smtpConnectTimeout = Duration(seconds: 30);

  ImapClient? _client;
  String? _selectedMailboxPath;
  Future<ImapClient>? _connectingFuture;

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
    _connectingFuture ??= _doConnect();
    try {
      return await _connectingFuture!;
    } catch (_) {
      _connectingFuture = null;
      rethrow;
    }
  }

  Future<ImapClient> _doConnect() async {
    final password = await _credentialStorage.loadPassword(_account.id);
    if (password == null) {
      throw const AuthException(message: 'No IMAP credentials stored');
    }

    final client = ImapClient(isLogEnabled: false);
    await client.connectToServer(
      _account.host,
      _account.port,
      isSecure: _account.useSsl,
    );
    await client.login(_account.emailAddress, password);
    _client = client;
    _selectedMailboxPath = null;
    _connectingFuture = null;
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
        // Don't pre-quote here — _encodeMailboxPath() quotes as needed and
        // would otherwise double-quote paths containing '(' or ')'
        // (e.g. "Audit(s)"), which servers reject with "Invalid characters
        // in atom".
        path: '$parentFolderId$sep',
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
        // BODYSTRUCTURE so `collectAttachments` can flag attachments on list
        // rows without the cost of fetching each body (`msg.body` is only
        // populated by a BODYSTRUCTURE/BODY[] fetch — ENVELOPE alone leaves it
        // null and every message reads as attachment-free).
        '(FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE)',
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
        // BODYSTRUCTURE so `collectAttachments` can flag attachments on list
        // rows without the cost of fetching each body (`msg.body` is only
        // populated by a BODYSTRUCTURE/BODY[] fetch — ENVELOPE alone leaves it
        // null and every message reads as attachment-free).
        '(FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE)',
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

  /// IMAP has no thread API. [conversationId] here *is* the normalized subject
  /// (see [_normalizeSubject]), and `SEARCH SUBJECT` is a case-insensitive
  /// substring match, so it returns the "Re:"/"Fwd:" replies as well. Hits
  /// that merely contain the subject as a substring are dropped afterwards by
  /// re-normalizing each result.
  ///
  /// Unlike Graph and Gmail this cannot span folders — [folderId] (defaulting
  /// to INBOX) bounds the search.
  @override
  Future<List<EmailModel>> getConversationMessages(
    String conversationId, {
    String? folderId,
  }) async {
    final mailboxPath = folderId ?? 'INBOX';
    try {
      final client = await _getConnectedClient();
      await _selectMailboxPath(client, mailboxPath);

      final escaped =
          conversationId.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      final searchResult =
          await client.uidSearchMessages(searchCriteria: 'SUBJECT "$escaped"');
      final uids = searchResult.matchingSequence?.toList() ?? [];
      if (uids.isEmpty) return [];

      final page = uids.reversed.take(_threadFetchLimit).toList();
      final sequence = MessageSequence.fromIds(page, isUid: true);
      final fetchResult = await client.uidFetchMessages(
        sequence,
        // BODYSTRUCTURE so `collectAttachments` can flag attachments on list
        // rows without the cost of fetching each body (`msg.body` is only
        // populated by a BODYSTRUCTURE/BODY[] fetch — ENVELOPE alone leaves it
        // null and every message reads as attachment-free).
        '(FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE)',
      );

      return fetchResult.messages
          .map((msg) =>
              _parseToModel(msg, folderId: _selectedMailboxPath ?? mailboxPath))
          .where((e) => e.conversationId == conversationId)
          .toList();
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    } on AuthException {
      rethrow;
    }
  }

  /// Upper bound on messages fetched for a single thread.
  static const _threadFetchLimit = 200;

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
      // BODY[] only — deliberately NOT BODYSTRUCTURE. `collectAttachments`
      // reads the real MIME headers of the parsed body, which is reliable; the
      // moment `msg.body` is populated by BODYSTRUCTURE it switches to the
      // BODYSTRUCTURE tree instead, whose disposition/filename parsing is
      // flakier. The list fetches carry BODYSTRUCTURE because they have no
      // BODY[] to parse; a single-message read does.
      final fetchResult = await client.uidFetchMessages(
        sequence,
        '(FLAGS INTERNALDATE ENVELOPE BODY[])',
      );

      if (fetchResult.messages.isEmpty) {
        throw ServerException(message: 'Message not found: $id');
      }

      final msg = fetchResult.messages.first;
      final folderId = _selectedMailboxPath ?? mailboxPath;

      // Hand the raw MIME to a background isolate to decode. The UID and
      // `\Seen` flag come from the FETCH rather than the MIME, so they travel
      // alongside it.
      String? rawMime;
      try {
        rawMime = msg.renderMessage();
      } catch (_) {
        rawMime = null;
      }
      if (rawMime == null || rawMime.isEmpty) {
        // No raw source to re-parse from (a server that answered BODY[] with
        // nothing renderable). Parse here rather than fail the read.
        return _parseToModel(msg, folderId: folderId, fullBody: true);
      }

      return compute(
        parseFullImapMessage,
        ImapFullMessageParams(
          rawMime: rawMime,
          folderId: folderId,
          uid: msg.uid ?? msg.sequenceId ?? 0,
          isRead: msg.isSeen,
          receivedAt: msg.decodeDate(),
        ),
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

  /// Parses a full message from its raw MIME source. [compute] entry point.
  ///
  /// The fetch has to happen on the calling isolate — the IMAP connection is
  /// stateful, with one selected mailbox, and cannot be shared — but the fetch
  /// itself is cheap: enough_mail decodes lazily, so `uidFetchMessages` only
  /// hands back a message whose body is still raw. The expensive half is what
  /// [_parseToModel] then triggers: `decodeTextHtmlPart` (charset plus
  /// quoted-printable/base64 over the whole body) and `decodeContentBinary` per
  /// inline image. That is what moves here.
  ///
  /// Reconstructing the message from text rather than sending the fetched
  /// [MimeMessage] across is deliberate — it is a lazily-parsed object graph,
  /// not plain data — and `renderMessage`/`parseFromText` are a documented
  /// round-trip. Rendering costs a string copy of already-raw bytes, which is
  /// why this is a win rather than a shuffle.
  static EmailModel parseFullImapMessage(ImapFullMessageParams params) {
    final msg = MimeMessage.parseFromText(params.rawMime);
    return _parseToModel(
      msg,
      folderId: params.folderId,
      fullBody: true,
      uid: params.uid,
      isRead: params.isRead,
      receivedAt: params.receivedAt,
    );
  }

  /// Builds the model for a fetched message.
  ///
  /// [uid], [isRead] and [receivedAt] exist because they are **IMAP-level**
  /// facts, not MIME ones: the UID and the `\Seen` flag come from the FETCH
  /// response, so a message reconstructed from its raw MIME alone (which is what
  /// [parseFullImapMessage] does on a background isolate) has no way to know
  /// them. Callers holding the fetched message leave them null and they are read
  /// off it as before.
  ///
  /// Static so [compute] can reach it; it never touched instance state.
  static EmailModel _parseToModel(
    MimeMessage msg, {
    required String folderId,
    bool fullBody = false,
    int? uid,
    bool? isRead,
    DateTime? receivedAt,
  }) {
    final resolvedUid = uid ?? msg.uid ?? msg.sequenceId ?? 0;
    final id = '$folderId:$resolvedUid';
    final resolvedIsRead = isRead ?? msg.isSeen;
    final date = receivedAt ?? msg.decodeDate() ?? DateTime.now().toUtc();

    String body = '';
    EmailBodyType bodyType = EmailBodyType.text;

    List<EmailAttachment> attachments = const [];
    List<InlineAttachment> inlineAttachments = const [];

    // Detected from BODYSTRUCTURE (present on both list and full-body fetches),
    // so the list paperclip and the reading-pane chips agree. Computed even
    // when !fullBody purely for the `hasAttachments` flag below.
    final attachmentParts = collectAttachments(msg);

    if (fullBody) {
      final html = msg.decodeTextHtmlPart();
      if (html != null && html.isNotEmpty) {
        body = html;
        bodyType = EmailBodyType.html;
      } else {
        final plain = msg.decodeTextPlainPart();
        body = plain ?? '';
      }

      attachments = attachmentParts;

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
      isRead: resolvedIsRead,
      receivedDateTime: date,
      importance: EmailImportance.normal,
      conversationId: _normalizeSubject(msg.decodeSubject() ?? ''),
      parentFolderId: folderId,
      // An IMAP message lives in exactly one mailbox, the one it was read from.
      folderIds: [folderId],
      hasAttachments: attachmentParts.isNotEmpty,
      attachments: attachments,
      inlineAttachments: inlineAttachments,
    );
  }

  /// Collects the downloadable attachments of [msg] from its BODYSTRUCTURE.
  ///
  /// enough_mail's `hasAttachments()` and `findContentInfo(disposition:
  /// attachment)` match only on an explicit `Content-Disposition: attachment`
  /// header (see `collectContentInfo` in the vendored package). Some servers
  /// and clients ship an attachment declared solely via `Content-Type:
  /// ...; name="x"` with no disposition at all, which those helpers miss
  /// entirely. So detect by filename as well — mirroring the Gmail datasource.
  ///
  /// **What is excluded is a part the body can actually reference — i.e. one
  /// with a `Content-Id` — not merely one marked `Content-Disposition: inline`.**
  /// Those are two different things, and conflating them silently loses
  /// attachments. Apple Mail sends photos as `image/jpeg` parts marked `inline`
  /// *with* a filename and *without* a `Content-Id`: nothing in the body can
  /// point at them, so skipping them as "the body renders these" means they are
  /// rendered nowhere and offered as no chip. A cid-less part therefore belongs
  /// in this list regardless of its disposition; the inline collection in
  /// [_parseToModel] skips exactly the same parts for the mirror-image reason
  /// (no cid to satisfy).
  ///
  /// Multipart containers are always excluded — they hold parts, they are not
  /// one.
  ///
  /// Each attachment's `id` is the IMAP part number (`fetchId`, e.g. `2` or
  /// `1.2`) that [downloadAttachment] later feeds to `getPart`.
  ///
  /// Two sources, by fetch shape:
  /// * List/search/thread rows carry BODYSTRUCTURE but no BODY[], so `msg.body`
  ///   is set and we walk that tree — enough to light the list paperclip.
  /// * A single-message read carries BODY[] but no BODYSTRUCTURE (see the
  ///   fetch in [getEmail]), so `msg.body` is null and we walk the parsed
  ///   message's real MIME headers instead — see
  ///   [_collectAttachmentsFromHeaders]. The read deliberately keeps `msg.body`
  ///   null to stay on that path, which reads the true headers rather than
  ///   enough_mail's flakier BODYSTRUCTURE disposition parsing.
  ///
  /// Both paths apply the *same* rules, filename fallback included. They did
  /// not always: the header path used to be
  /// `findContentInfo(disposition: attachment)`, which matches only an explicit
  /// `Content-Disposition: attachment`, so a message whose attachment is
  /// declared solely via `Content-Type; name="x"` lit the list paperclip (from
  /// BODYSTRUCTURE, which had the fallback) and then rendered no chips.
  @visibleForTesting
  static List<EmailAttachment> collectAttachments(MimeMessage msg) {
    final structure = msg.body;
    if (structure == null) {
      final result = <EmailAttachment>[];
      _collectAttachmentsFromHeaders(msg, null, result);
      return result;
    }
    final result = <EmailAttachment>[];
    _walkAttachments(structure, result);
    return result;
  }

  /// Header-path twin of [_walkAttachments]: applies the same attachment rules
  /// to the real MIME headers of a message parsed from a `BODY[]` fetch.
  ///
  /// [fetchId] is built positionally exactly as enough_mail's own
  /// `MimePart.collectContentInfo` builds it, so the ids stay compatible with
  /// the `getPart` lookup in [downloadAttachment].
  ///
  /// Size stays 0 on this path: only BODYSTRUCTURE reports part sizes, and
  /// decoding each part just to measure it would pull every attachment's bytes
  /// into memory on every message open. This matches what the previous
  /// `findContentInfo` implementation produced here.
  static void _collectAttachmentsFromHeaders(
    MimePart part,
    String? fetchId,
    List<EmailAttachment> out,
  ) {
    final contentType = part.getHeaderContentType();
    // Multipart parts are containers, never chips — recurse past them.
    if (contentType?.mediaType.top != MediaToptype.multipart) {
      final disposition = part.getHeaderContentDisposition()?.disposition;
      final fileName = part.decodeFileName();
      final cid = part.getHeaderValue('content-id');
      final hasCid = cid != null && cid.isNotEmpty;
      final isAttachment = disposition == ContentDisposition.attachment ||
          (!hasCid &&
              !_isBodyTextPart(contentType?.mediaType.sub, disposition) &&
              (fileName?.isNotEmpty ?? false));
      if (isAttachment && fetchId != null && fetchId.isNotEmpty) {
        out.add(EmailAttachment(
          id: fetchId,
          name: (fileName?.isNotEmpty ?? false) ? fileName! : 'Attachment',
          contentType:
              contentType?.mediaType.text ?? 'application/octet-stream',
          size: 0,
        ));
      }
    }

    final parts = part.parts;
    if (parts == null || parts.isEmpty) return;
    for (var i = 0; i < parts.length; i++) {
      final childFetchId = part.mediaType.sub == MediaSubtype.messageRfc822
          ? fetchId
          : fetchId == null
              ? '${i + 1}'
              : '$fetchId.${i + 1}';
      _collectAttachmentsFromHeaders(parts[i], childFetchId, out);
    }
  }

  static void _walkAttachments(BodyPart part, List<EmailAttachment> out) {
    if (part.contentType?.mediaType.top == MediaToptype.multipart) {
      for (final child in part.parts ?? const <BodyPart>[]) {
        _walkAttachments(child, out);
      }
      return;
    }

    final disposition = part.contentDisposition?.disposition;
    final fileName = _partFileName(part);
    final hasCid = part.cid != null && part.cid!.isNotEmpty;
    final isAttachment = disposition == ContentDisposition.attachment ||
        (!hasCid &&
            !_isBodyTextPart(part.contentType?.mediaType.sub, disposition) &&
            fileName != null);
    if (!isAttachment) return;

    final fetchId = part.fetchId;
    if (fetchId == null || fetchId.isEmpty) return;

    out.add(EmailAttachment(
      id: fetchId,
      name: fileName ?? 'Attachment',
      contentType: part.contentType?.mediaType.text ?? 'application/octet-stream',
      size: part.size ?? 0,
    ));
  }

  /// Whether a part is the message body rather than a candidate attachment.
  ///
  /// Dropping the "inline means never a chip" rule (see [collectAttachments])
  /// opens one hole: some mailers label the body itself
  /// `Content-Disposition: inline; filename="message.html"`, and a filename is
  /// otherwise enough to make a part a chip. A `text/plain` or `text/html` part
  /// is the body unless the sender explicitly said `attachment`, so require
  /// that disposition for those two subtypes. Other text subtypes — notably
  /// `text/calendar` invites, which arrive as `; name="meeting.ics"` with no
  /// disposition at all — stay detectable by filename.
  static bool _isBodyTextPart(
    MediaSubtype? subtype,
    ContentDisposition? disposition,
  ) =>
      disposition != ContentDisposition.attachment &&
      (subtype == MediaSubtype.textPlain || subtype == MediaSubtype.textHtml);

  /// The attachment filename of a BODYSTRUCTURE [part].
  ///
  /// enough_mail builds a BODYSTRUCTURE `ContentDispositionHeader` from just
  /// the `attachment`/`inline` token and then loads its `filename` via
  /// `setParameter`, which — unlike the raw-header parser — leaves the
  /// `.filename` getter null and does NOT lowercase parameter keys or strip
  /// quotes. So read the parameter maps directly and case-insensitively,
  /// preferring `Content-Disposition; filename` and falling back to the
  /// `Content-Type; name` some senders use instead.
  static String? _partFileName(BodyPart part) {
    final fromDisposition = part.contentDisposition?.filename;
    if (fromDisposition != null && fromDisposition.isNotEmpty) {
      return fromDisposition;
    }
    return _lookupParam(part.contentDisposition?.parameters, 'filename') ??
        _lookupParam(part.contentType?.parameters, 'name');
  }

  static String? _lookupParam(Map<String, String>? params, String key) {
    if (params == null || params.isEmpty) return null;
    for (final entry in params.entries) {
      if (entry.key.toLowerCase() != key) continue;
      var value = entry.value.trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      if (value.isNotEmpty) return value;
    }
    return null;
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
    _connectingFuture = null;
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

    final host = _account.smtpHost;
    final port = _account.smtpPort;
    final useSsl = _account.smtpUseSsl;
    final server = '$host:$port';

    final client = SmtpClient('nightmail', isLogEnabled: false);
    try {
      // `connectToServer`'s own timeout covers the TCP connect only, not the
      // greeting that follows — so plaintext against an implicit-TLS port
      // (usually 465) leaves the server waiting for a handshake and the send
      // waiting for a greeting, forever. Bound the whole exchange instead.
      await _connectAndAuthenticate(client, password).timeout(
        _smtpConnectTimeout,
        onTimeout: () => throw ServerException(
          message: 'The SMTP server $server did not respond within '
              '${_smtpConnectTimeout.inSeconds}s.'
              '${useSsl ? '' : ' If this is an implicit-TLS port (usually 465), '
                  'it is waiting for a TLS handshake that never comes — turn '
                  '"Use SSL" on for outgoing mail.'}',
        ),
      );
      return client;
    } catch (e) {
      // `disconnect`, not `quit`: a socket that just died mid-handshake throws
      // again when QUIT is written to it, which would replace the real error.
      try {
        await client.disconnect();
      } catch (_) {}
      throw describeSmtpConnectFailure(e, server, useSsl);
    }
  }

  Future<void> _connectAndAuthenticate(
    SmtpClient client,
    String password,
  ) async {
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
  }

  /// Maps an SMTP connect/authenticate failure onto this layer's exception
  /// vocabulary so the repository turns it into a `Failure` with a message
  /// worth reading. Anything unrecognised is passed through untouched.
  @visibleForTesting
  static Object describeSmtpConnectFailure(
    Object error,
    String server,
    bool useSsl,
  ) {
    // HandshakeException is a TlsException, so this covers both.
    if (error is TlsException) {
      return ServerException(
        message: describeSmtpTlsFailure(error, server, useSsl),
      );
    }
    if (error is SocketException) {
      return NetworkException(
        message: 'Cannot reach SMTP server $server: '
            '${error.osError?.message ?? error.message}',
      );
    }
    if (error is SmtpException) {
      final detail = error.message ?? error.response.errorMessage;
      final code = error.response.code;
      // A rejected AUTH is a credential problem, not a server problem — it has
      // to arrive as an AuthFailure to prompt for re-authentication.
      if (code == 535 || code == 534 || code == 530) {
        return AuthException(message: 'SMTP rejected the sign-in: $detail');
      }
      return ServerException(
        message: 'SMTP server $server refused the connection: $detail',
        statusCode: code,
      );
    }
    return error;
  }

  /// Turns Dart's opaque `HandshakeException: Handshake error in client` into
  /// something a user can act on. The two causes we can name are worth naming:
  /// TLS-on-a-plaintext-port (the default 587 with "Use SSL" ticked) reads as
  /// garbage in the handshake, and an untrusted certificate says so in the
  /// nested OS error. The raw text is kept on the end either way, because for
  /// anything else it is the only clue there is.
  @visibleForTesting
  static String describeSmtpTlsFailure(
    Object error,
    String server,
    bool useSsl,
  ) {
    final raw = error.toString();
    final lower = raw.toLowerCase();

    if (lower.contains('certificate')) {
      return 'The SMTP server $server presented a certificate that could not '
          'be verified. Check the host name matches the certificate. ($raw)';
    }
    if (useSsl) {
      return 'TLS handshake with $server failed. "Use SSL" is on, so NightMail '
          'expects TLS from the first byte — if this is a STARTTLS port '
          '(usually 587) turn "Use SSL" off, or switch to the implicit-TLS '
          'port (usually 465). ($raw)';
    }
    return 'STARTTLS upgrade with $server failed after the server advertised '
        'support for it. ($raw)';
  }

  Future<void> _sendMime(MimeMessage message) async {
    final smtpClient = await _getSmtpClient();
    try {
      final response = await smtpClient.sendMessage(message);
      if (!response.isOkStatus) {
        throw ServerException(message: 'SMTP error: ${response.code}');
      }
    } on SmtpException catch (e) {
      throw ServerException(
        message: e.message ?? 'SMTP error',
        statusCode: e.response.code,
      );
    } finally {
      // QUIT is a courtesy. If the send failed because the connection dropped,
      // writing it throws — and an exception out of `finally` would replace the
      // real send error with a meaningless socket one.
      try {
        await smtpClient.quit();
      } catch (_) {}
    }

    // Plain SMTP has no concept of a Sent folder — unlike the Gmail/Graph
    // API paths, which save a Sent copy server-side, IMAP accounts need an
    // explicit APPEND after a successful send. Best-effort: a missing Sent
    // folder or a failed APPEND must not surface as a send failure, since
    // the message has already been delivered.
    try {
      final imapClient = await _getConnectedClient();
      final sentPath = await _findSentPath(imapClient);
      if (sentPath != null) {
        await imapClient.appendMessageText(
          message.renderMessage(),
          targetMailboxPath: sentPath,
          flags: [MessageFlags.seen],
        );
      }
    } catch (_) {}
  }

  Future<String?> _findSentPath(ImapClient client) async {
    try {
      final mailboxes = await client.listMailboxes(recursive: true);
      final sentMailbox = mailboxes.where((mb) => mb.isSent).firstOrNull ??
          _wellKnownSentMailbox(mailboxes);
      if (sentMailbox == null) return null;
      return (_inboxFolderPrefix.isNotEmpty &&
              !sentMailbox.path.toUpperCase().startsWith('INBOX'))
          ? '$_inboxFolderPrefix${sentMailbox.path}'
          : sentMailbox.path;
    } on ImapException {
      return null;
    }
  }

  Mailbox? _wellKnownSentMailbox(List<Mailbox> mailboxes) {
    const wellKnown = ['Sent', 'Sent Items', 'Sent Mail', 'Sent Messages'];
    for (final name in wellKnown) {
      final fullName =
          _inboxFolderPrefix.isNotEmpty ? '$_inboxFolderPrefix$name' : name;
      final match = mailboxes
          .where(
            (mb) =>
                mb.path.toLowerCase() == fullName.toLowerCase() ||
                mb.path.toLowerCase() == name.toLowerCase() ||
                mb.path.split(_pathSeparator).last.toLowerCase() ==
                    name.toLowerCase(),
          )
          .firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  @override
  Future<void> sendEmail({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    final builder = MessageBuilder()
      ..from = [MailAddress(_account.senderName, _account.emailAddress)]
      ..to = toAddresses.map((e) => MailAddress(null, e)).toList()
      ..cc = ccAddresses.map((e) => MailAddress(null, e)).toList()
      ..subject = subject;
    if (bodyType == EmailBodyType.html) {
      builder.addTextHtml(body);
    } else {
      builder.addTextPlain(body);
    }
    await _addAttachmentsToBuilder(builder, newAttachments);
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
    List<String> toAddresses = const [],
    List<String> ccAddresses = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    final original = await _fetchOriginal(messageId);
    final builder = MessageBuilder.prepareReplyToMessage(
      original,
      MailAddress(_account.senderName, _account.emailAddress),
      replyAll: replyAll,
    );
    if (toAddresses.isNotEmpty) {
      builder.to = toAddresses.map((a) => MailAddress(null, a)).toList();
    }
    if (ccAddresses.isNotEmpty) {
      builder.cc = ccAddresses.map((a) => MailAddress(null, a)).toList();
    }
    if (bodyType == EmailBodyType.html) {
      builder.addTextHtml(comment);
    } else {
      builder.addTextPlain(comment);
    }
    await _addAttachmentsToBuilder(builder, newAttachments);
    await _sendMime(builder.buildMimeMessage());
  }

  @override
  Future<void> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String comment,
    List<String> excludedAttachmentIds = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    final original = await _fetchOriginal(messageId);

    final originalSubject = original.decodeSubject() ?? '';
    final fwdSubject = originalSubject.startsWith('Fwd:')
        ? originalSubject
        : 'Fwd: $originalSubject';

    // Build a plain message — compose body already contains the quoted content
    // the user can edit, so we don't auto-append via prepareForwardMessage.
    final builder = MessageBuilder()
      ..from = [MailAddress(_account.senderName, _account.emailAddress)]
      ..to = toAddresses.map((e) => MailAddress(null, e)).toList()
      ..subject = fwdSubject;

    if (ccAddresses.isNotEmpty) {
      builder.cc = ccAddresses.map((e) => MailAddress(null, e)).toList();
    }

    if (bodyType == EmailBodyType.html) {
      builder.addTextHtml(comment);
    } else {
      builder.addTextPlain(comment);
    }

    for (final info
        in original.findContentInfo(disposition: ContentDisposition.attachment)) {
      if (excludedAttachmentIds.contains(info.fetchId)) continue;
      final bytes = original.getPart(info.fetchId)?.decodeContentBinary();
      if (bytes == null || bytes.isEmpty) continue;
      builder.addBinary(
        bytes,
        MediaType.fromText(
            info.contentType?.mediaType.text ?? 'application/octet-stream'),
        filename: info.fileName,
      );
    }

    await _addAttachmentsToBuilder(builder, newAttachments);
    await _sendMime(builder.buildMimeMessage());
  }

  Future<void> _addAttachmentsToBuilder(
      MessageBuilder builder, List<LocalAttachment> attachments) async {
    for (final att in attachments) {
      if (att.isInline && att.contentId != null) {
        final part = builder.addBinary(
          att.bytes,
          MediaType.fromText(att.mimeType),
          filename: att.name,
          disposition: ContentDispositionHeader.from(ContentDisposition.inline),
        );
        part.setHeader('Content-Id', '<${att.contentId}>');
      } else {
        builder.addBinary(
          att.bytes,
          MediaType.fromText(att.mimeType),
          filename: att.name,
        );
      }
    }
  }

  @override
  Future<String?> moveEmail(String id, String destinationFolderId) async {
    final separatorIdx = id.lastIndexOf(':');
    final mailboxPath =
        separatorIdx > 0 ? id.substring(0, separatorIdx) : 'INBOX';
    final uid = int.tryParse(id.substring(separatorIdx + 1)) ?? 0;

    try {
      final client = await _getConnectedClient();
      await _selectMailboxPath(client, mailboxPath);

      // Apply INBOX prefix normalization to the destination path using the
      // same logic as getMailFolders(). On abbreviated-namespace servers
      // (Courier, some Dovecot), the folder list may return "Archive" but
      // UID COPY / UID MOVE require the full path "INBOX.Archive".
      final resolvedDest =
          (_inboxFolderPrefix.isNotEmpty &&
                  !destinationFolderId.toUpperCase().startsWith('INBOX'))
              ? '$_inboxFolderPrefix$destinationFolderId'
              : destinationFolderId;

      final sequence = MessageSequence.fromId(uid, isUid: true);
      if (client.serverInfo.supportsMove) {
        await client.uidMove(sequence, targetMailboxPath: resolvedDest);
      } else {
        await client.uidCopy(sequence, targetMailboxPath: resolvedDest);
        await client.uidStore(
          sequence,
          [MessageFlags.deleted],
          action: StoreAction.add,
        );
        if (client.serverInfo.supportsUidPlus) {
          await client.uidExpunge(sequence);
        } else {
          await client.expunge();
        }
      }
      // The destination mailbox assigns its own UID (via the untagged
      // COPYUID response on UIDPLUS servers), which this wrapper doesn't
      // currently capture — returning null rather than guessing avoids
      // remapping the outbox to an id that doesn't exist.
      return null;
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  @override
  Future<String?> reportJunk(String id) async {
    final separatorIdx = id.lastIndexOf(':');
    final mailboxPath =
        separatorIdx > 0 ? id.substring(0, separatorIdx) : 'INBOX';
    final uid = int.tryParse(id.substring(separatorIdx + 1)) ?? 0;

    try {
      final client = await _getConnectedClient();
      final junkPath = await _findJunkPath(client);
      if (junkPath == null) {
        throw const ServerException(message: 'Junk folder not found');
      }
      await _selectMailboxPath(client, mailboxPath);
      final sequence = MessageSequence.fromId(uid, isUid: true);
      await client.uidCopy(sequence, targetMailboxPath: junkPath);
      await client.uidStore(
        sequence,
        [MessageFlags.deleted],
        action: StoreAction.add,
      );
      await client.expunge();
      return null;
    } on ServerException {
      rethrow;
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  Future<String?> _findDraftsPath(ImapClient client) async {
    try {
      final mailboxes = await client.listMailboxes(recursive: true);
      final draftsMailbox = mailboxes.where((mb) => mb.isDrafts).firstOrNull ??
          _wellKnownDraftsMailbox(mailboxes);
      if (draftsMailbox == null) return null;
      return (_inboxFolderPrefix.isNotEmpty &&
              !draftsMailbox.path.toUpperCase().startsWith('INBOX'))
          ? '$_inboxFolderPrefix${draftsMailbox.path}'
          : draftsMailbox.path;
    } on ImapException {
      return null;
    }
  }

  Mailbox? _wellKnownDraftsMailbox(List<Mailbox> mailboxes) {
    const wellKnown = ['Drafts', 'Draft', 'Draft Items'];
    for (final name in wellKnown) {
      final fullName =
          _inboxFolderPrefix.isNotEmpty ? '$_inboxFolderPrefix$name' : name;
      final match = mailboxes
          .where(
            (mb) =>
                mb.path.toLowerCase() == fullName.toLowerCase() ||
                mb.path.toLowerCase() == name.toLowerCase() ||
                mb.path.split(_pathSeparator).last.toLowerCase() ==
                    name.toLowerCase(),
          )
          .firstOrNull;
      if (match != null) return match;
    }
    return null;
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
                mb.path.toLowerCase() == name.toLowerCase() ||
                mb.path.split(_pathSeparator).last.toLowerCase() ==
                    name.toLowerCase(),
          )
          .firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  /// Locates the `SPAMDB` mailbox used to sync the client-side spam filter
  /// (see [SpamDbSyncDatasource]). Unlike Junk/Sent/Drafts/Trash this has no
  /// RFC 6154 special-use flag — it's a literal folder name NightMail itself
  /// creates and manages, so the match is name-only. Returns null if not
  /// found and [create] is false; otherwise creates it and returns its path.
  Future<String?> _findSpamDbPath(ImapClient client, {bool create = false}) async {
    try {
      final mailboxes = await client.listMailboxes(recursive: true);
      final match = mailboxes
          .where(
            (mb) =>
                mb.path.toLowerCase() == _spamDbFolderName.toLowerCase() ||
                mb.path.split(_pathSeparator).last.toLowerCase() ==
                    _spamDbFolderName.toLowerCase(),
          )
          .firstOrNull;
      if (match != null) {
        return (_inboxFolderPrefix.isNotEmpty &&
                !match.path.toUpperCase().startsWith('INBOX'))
            ? '$_inboxFolderPrefix${match.path}'
            : match.path;
      }
      if (!create) return null;
      final newPath = _inboxFolderPrefix.isNotEmpty
          ? '$_inboxFolderPrefix$_spamDbFolderName'
          : _spamDbFolderName;
      await client.createMailbox(newPath);
      return newPath;
    } on ImapException {
      return null;
    }
  }

  @override
  Future<int?> peekSpamDbVersion() async {
    try {
      final client = await _getConnectedClient();
      final path = await _findSpamDbPath(client);
      if (path == null) return null;
      await _selectMailboxPath(client, path);

      final searchResult = await client.uidSearchMessages(searchCriteria: 'ALL');
      final uids = searchResult.matchingSequence?.toList() ?? [];
      if (uids.isEmpty) return null;

      final sequence = MessageSequence.fromIds(uids, isUid: true);
      final fetchResult = await client.uidFetchMessages(
        sequence,
        'BODY.PEEK[HEADER.FIELDS ($_spamDbVersionHeader)]',
      );

      int? bestVersion;
      int? bestUid;
      for (final msg in fetchResult.messages) {
        final raw = msg.getHeaderValue(_spamDbVersionHeader);
        final version = raw != null ? int.tryParse(raw.trim()) : null;
        // uids (from uidSearchMessages) are real UIDs — msg.uid must be used
        // here, not a sequenceId fallback, or a null uid on the winning
        // message would produce a bestUid that matches nothing in uids and
        // the "stale" filter below would wipe every message, including the
        // one we meant to keep.
        final uid = msg.uid;
        if (version != null &&
            uid != null &&
            (bestVersion == null || version > bestVersion)) {
          bestVersion = version;
          bestUid = uid;
        }
      }
      if (bestVersion == null || bestUid == null) return null;

      // Self-heal: a race between two clients pushing concurrently can leave
      // more than one message behind (append-then-delete-old isn't atomic).
      // Collapse back down to just the highest-versioned message.
      final staleUids = uids.where((u) => u != bestUid).toList();
      if (staleUids.isNotEmpty) {
        final staleSequence = MessageSequence.fromIds(staleUids, isUid: true);
        await client.uidStore(
          staleSequence,
          [MessageFlags.deleted],
          action: StoreAction.add,
        );
        await client.expunge();
      }
      return bestVersion;
    } on ImapException {
      return null;
    }
  }

  @override
  Future<String?> downloadSpamDbPayload() async {
    try {
      final client = await _getConnectedClient();
      final path = await _findSpamDbPath(client);
      if (path == null) return null;
      await _selectMailboxPath(client, path);

      final searchResult = await client.uidSearchMessages(searchCriteria: 'ALL');
      final uids = searchResult.matchingSequence?.toList() ?? [];
      if (uids.isEmpty) return null;

      // peekSpamDbVersion() collapses SPAMDB to a single message before this
      // is called; picking the highest UID is a defensive fallback only.
      final sequence = MessageSequence.fromId(uids.last, isUid: true);
      final fetchResult = await client.uidFetchMessages(sequence, 'BODY.PEEK[]');
      final msg = fetchResult.messages.firstOrNull;
      if (msg == null) return null;
      return msg.decodeTextPlainPart();
    } on ImapException {
      return null;
    }
  }

  @override
  Future<void> pushSpamDb({required int version, required String payload}) async {
    try {
      final client = await _getConnectedClient();
      final path = await _findSpamDbPath(client, create: true);
      if (path == null) {
        throw const ServerException(message: 'Could not create SPAMDB mailbox');
      }

      final msgId = MessageBuilder.createMessageId(
        _account.emailAddress.split('@').last,
      );
      final builder = MessageBuilder()
        ..from = [MailAddress(_account.senderName, _account.emailAddress)]
        ..subject = 'NightMail Spam Database (auto-generated, do not delete)'
        ..messageId = msgId
        ..addTextPlain(payload);
      builder.setHeader(_spamDbVersionHeader, version.toString());

      await client.appendMessageText(
        builder.buildMimeMessage().renderMessage(),
        targetMailboxPath: path,
        flags: [MessageFlags.seen],
      );

      await _selectMailboxPath(client, path);
      final newSearch = await client.uidSearchMessages(
        searchCriteria: 'HEADER Message-Id "$msgId"',
      );
      final newUid = newSearch.matchingSequence?.toList().firstOrNull;

      final allSearch = await client.uidSearchMessages(searchCriteria: 'ALL');
      final allUids = allSearch.matchingSequence?.toList() ?? [];
      final staleUids =
          newUid != null ? allUids.where((u) => u != newUid).toList() : <int>[];
      if (staleUids.isNotEmpty) {
        final staleSequence = MessageSequence.fromIds(staleUids, isUid: true);
        await client.uidStore(
          staleSequence,
          [MessageFlags.deleted],
          action: StoreAction.add,
        );
        await client.expunge();
      }
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
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
  Future<String> createServerDraft({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final client = await _getConnectedClient();
      final draftsPath = await _findDraftsPath(client);
      if (draftsPath == null) {
        throw const ServerException(message: 'Drafts mailbox not found');
      }
      final msgId = MessageBuilder.createMessageId(
        _account.emailAddress.split('@').last,
      );
      final mimeText = await compute(_buildDraftMimeText, _DraftMimeParams(
        fromName: _account.senderName,
        fromAddress: _account.emailAddress,
        toAddresses: toAddresses,
        ccAddresses: ccAddresses,
        subject: subject,
        body: body,
        isHtml: bodyType == EmailBodyType.html,
        attachments: newAttachments,
        messageId: msgId,
      ));
      await client.appendMessageText(
        mimeText,
        targetMailboxPath: draftsPath,
        flags: [MessageFlags.draft],
      );
      await _selectMailboxPath(client, draftsPath);
      final searchResult = await client.uidSearchMessages(
        searchCriteria: 'HEADER Message-Id "$msgId"',
      );
      final uid = searchResult.matchingSequence?.toList().firstOrNull;
      if (uid == null) {
        throw const ServerException(message: 'Draft not found after append');
      }
      return '$draftsPath:$uid';
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  @override
  Future<String> updateServerDraft({
    required String draftId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    final separatorIdx = draftId.lastIndexOf(':');
    final draftsPath =
        separatorIdx > 0 ? draftId.substring(0, separatorIdx) : 'Drafts';
    final oldUid = int.tryParse(draftId.substring(separatorIdx + 1)) ?? 0;
    try {
      final client = await _getConnectedClient();
      final msgId = MessageBuilder.createMessageId(
        _account.emailAddress.split('@').last,
      );
      final mimeText = await compute(_buildDraftMimeText, _DraftMimeParams(
        fromName: _account.senderName,
        fromAddress: _account.emailAddress,
        toAddresses: toAddresses,
        ccAddresses: ccAddresses,
        subject: subject,
        body: body,
        isHtml: bodyType == EmailBodyType.html,
        attachments: newAttachments,
        messageId: msgId,
      ));
      await client.appendMessageText(
        mimeText,
        targetMailboxPath: draftsPath,
        flags: [MessageFlags.draft],
      );
      await _selectMailboxPath(client, draftsPath);
      final searchResult = await client.uidSearchMessages(
        searchCriteria: 'HEADER Message-Id "$msgId"',
      );
      final newUid = searchResult.matchingSequence?.toList().firstOrNull;
      if (oldUid > 0) {
        final oldSeq = MessageSequence.fromId(oldUid, isUid: true);
        await client.uidStore(
          oldSeq,
          [MessageFlags.deleted],
          action: StoreAction.add,
        );
        await client.expunge();
      }
      return newUid != null ? '$draftsPath:$newUid' : draftId;
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  @override
  Future<void> deleteServerDraft({required String draftId}) async {
    final separatorIdx = draftId.lastIndexOf(':');
    final mailboxPath =
        separatorIdx > 0 ? draftId.substring(0, separatorIdx) : 'Drafts';
    final uid = int.tryParse(draftId.substring(separatorIdx + 1)) ?? 0;
    if (uid == 0) return;
    try {
      final client = await _getConnectedClient();
      await _selectMailboxPath(client, mailboxPath);
      final sequence = MessageSequence.fromId(uid, isUid: true);
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

  @override
  Future<void> renameFolder({
    required String folderId,
    required String newDisplayName,
  }) async {
    try {
      final client = await _getConnectedClient();
      final sep = _pathSeparator;
      final lastSep = folderId.lastIndexOf(sep);
      final newPath = lastSep >= 0
          ? '${folderId.substring(0, lastSep)}$sep$newDisplayName'
          : newDisplayName;
      final leafName = lastSep >= 0 ? folderId.substring(lastSep + sep.length) : folderId;
      final mailbox = Mailbox(
        encodedName: leafName,
        encodedPath: folderId,
        flags: [],
        pathSeparator: sep,
      );
      await client.renameMailbox(mailbox, newPath);
    } on ImapException catch (e) {
      throw ServerException(message: e.message ?? 'IMAP error');
    }
  }

  @override
  Future<void> moveFolder({
    required String folderId,
    required String newParentFolderId,
  }) async {
    try {
      final client = await _getConnectedClient();
      final sep = _pathSeparator;
      // Keep the leaf name; move it under the destination path. RFC 3501
      // requires RENAME to also relocate any inferior (child) mailboxes.
      final lastSep = folderId.lastIndexOf(sep);
      final leafName =
          lastSep >= 0 ? folderId.substring(lastSep + sep.length) : folderId;
      final newPath = '$newParentFolderId$sep$leafName';
      final mailbox = Mailbox(
        encodedName: leafName,
        encodedPath: folderId,
        flags: [],
        pathSeparator: sep,
      );
      await client.renameMailbox(mailbox, newPath);
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
                mb.path.toLowerCase() == name.toLowerCase() ||
                mb.path.split(_pathSeparator).last.toLowerCase() ==
                    name.toLowerCase(),
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

/// Inputs for [_buildDraftMimeText]. Kept as plain, isolate-transferable
/// data (no [MessageBuilder]/[MimeMessage] instances) since [compute] runs
/// the builder on a background isolate.
class _DraftMimeParams {
  const _DraftMimeParams({
    required this.fromName,
    required this.fromAddress,
    required this.toAddresses,
    required this.ccAddresses,
    required this.subject,
    required this.body,
    required this.isHtml,
    required this.attachments,
    required this.messageId,
  });

  final String fromName;
  final String fromAddress;
  final List<String> toAddresses;
  final List<String> ccAddresses;
  final String subject;
  final String body;
  final bool isHtml;
  final List<LocalAttachment> attachments;
  final String messageId;
}

/// Builds and renders a draft MIME message off the main isolate.
///
/// Encoding a large HTML body (a long quoted reply can be hundreds of KB)
/// via [MessageBuilder.buildMimeMessage] and [MimeMessage.renderMessage] is
/// synchronous CPU work; running it on the main isolate froze the compose
/// UI every time the draft autosave timer fired. [compute] moves it to a
/// worker isolate so only the cheap network I/O (APPEND) touches the
/// account's connection back on the caller's isolate.
String _buildDraftMimeText(_DraftMimeParams p) {
  final builder = MessageBuilder()
    ..from = [MailAddress(p.fromName, p.fromAddress)]
    ..to = p.toAddresses.map((a) => MailAddress(null, a)).toList()
    ..cc = p.ccAddresses.map((a) => MailAddress(null, a)).toList()
    ..subject = p.subject
    ..messageId = p.messageId;
  if (p.isHtml) {
    builder.addTextHtml(p.body);
  } else {
    builder.addTextPlain(p.body);
  }
  for (final att in p.attachments) {
    if (att.isInline && att.contentId != null) {
      final part = builder.addBinary(
        att.bytes,
        MediaType.fromText(att.mimeType),
        filename: att.name,
        disposition: ContentDispositionHeader.from(ContentDisposition.inline),
      );
      part.setHeader('Content-Id', '<${att.contentId}>');
    } else {
      builder.addBinary(
        att.bytes,
        MediaType.fromText(att.mimeType),
        filename: att.name,
      );
    }
  }
  return builder.buildMimeMessage().renderMessage();
}

/// Inputs for [ImapDatasourceImpl.parseFullImapMessage].
///
/// Kept as plain, isolate-transferable data — a raw MIME string plus the two
/// IMAP-level facts that are not represented in the MIME itself. Deliberately
/// not a [MimeMessage]: that is a lazily-parsed object graph rather than data,
/// which is the reason the source text is what crosses the boundary.
class ImapFullMessageParams {
  const ImapFullMessageParams({
    required this.rawMime,
    required this.folderId,
    required this.uid,
    required this.isRead,
    this.receivedAt,
  });

  /// The message's rendered MIME source, as returned by `renderMessage()`.
  final String rawMime;

  /// Mailbox the message was read from — its id is derived from this and [uid].
  final String folderId;

  /// From the FETCH response, not the MIME.
  final int uid;

  /// The `\Seen` flag, likewise from the FETCH response.
  final bool isRead;

  /// Decoded on the fetching isolate so the reconstructed message cannot
  /// disagree with what the list row already shows.
  final DateTime? receivedAt;
}
