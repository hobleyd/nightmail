import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../domain/entities/email.dart';
import '../../../domain/entities/email_address.dart';
import '../../../domain/entities/email_attachment.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../domain/entities/inline_attachment.dart';
import '../../database/app_database.dart';
import '../../services/inline_attachment_cache.dart';
import '../../../infrastructure/cache/cache_encryption_service.dart';
import 'email_local_datasource.dart';

class EmailLocalDatasourceImpl implements EmailLocalDatasource {
  const EmailLocalDatasourceImpl({
    required this._database,
    required this._encryption,
    required this._inlineAttachments,
  });

  final AppDatabase _database;
  final CacheEncryptionService _encryption;

  /// Inline images are cached on disk next to — but not inside — the SQLite
  /// cache, so removing a row here has to remove that email's files too.
  final InlineAttachmentCache _inlineAttachments;

  /// Stamped into every row this version writes, and bumped whenever the
  /// attachment-parsing code changes such that rows written before it may hold
  /// wrong attachment metadata. [hasStaleAttachmentParse] compares against it
  /// so those rows are refetched once instead of serving bad metadata forever.
  ///
  /// * 1 — implicit; rows with no stamp at all. The IMAP walks treated every
  ///   `Content-Disposition: inline` part as body-rendered, so a message whose
  ///   attachments are inline *without* a `Content-Id` (Apple Mail photos) was
  ///   cached with `hasAttachments: false` and an empty attachment list. The
  ///   reading-pane path additionally missed attachments declared only via
  ///   `Content-Type; name="x"`.
  /// * 2 — the IMAP header walk numbered parts inside a `message/rfc822` with
  ///   the id of the rfc822 part itself, so every attachment in a *forwarded*
  ///   message shared one id and downloaded the whole forward. The ids are
  ///   what a row stores, so a message read before the fix keeps them: the
  ///   chips look right and every one of them fetches the wrong bytes.
  static const attachmentParseVersion = 3;

  /// JSON key for [attachmentParseVersion]. Absent on pre-versioning rows,
  /// which read back as version 1.
  static const _parseVersionKey = 'attachmentParseVersion';

  @override
  Future<List<Email>> getCachedEmails({
    required String accountId,
    required String folderId,
  }) async {
    final rows = await (_database.select(_database.cachedEmails)
          ..where(
            (t) => t.accountId.equals(accountId) & t.folderId.equals(folderId),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.receivedDateTimeMs)]))
        .get();

    final emails = <Email>[];
    for (final row in rows) {
      final plaintext = await _encryption.decrypt(row.encryptedData);
      final json = jsonDecode(plaintext) as Map<String, dynamic>;
      emails.add(_emailFromJson(json));
    }
    return emails;
  }

  @override
  Future<void> cacheEmails({
    required String accountId,
    required String folderId,
    required List<Email> emails,
    bool replaceFolder = false,
  }) async {
    // An empty page never rewrites anything — and with [replaceFolder] it must
    // not *clear* anything either. An empty fetch is far more likely a
    // transient (or every message tombstoned by an in-flight mutation) than a
    // genuinely emptied folder, and clearing on it blanks the cache the app
    // repaints from offline. Callers used to guard this individually; it lives
    // here so every caller gets it.
    if (emails.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;

    // Encrypt all emails concurrently before opening the batch transaction
    final companions = await Future.wait(emails.map((email) async {
      var json = _emailToJson(email);

      // List/poll fetches only carry a preview (empty body, no attachments)
      // to stay cheap. A message already cached with a full body — from a
      // prior single-message open — must not have that body clobbered back
      // to empty just because it showed up again in a later folder/delta
      // sync; blind insertOrReplace would do exactly that.
      if (email.body.isEmpty) {
        // Any folder's copy will do — the body is a property of the message,
        // not of the listing it was seen in, so a body fetched while reading
        // this message in the Inbox is preserved onto the copy the Archive
        // page is about to write.
        final existing = await _anyCachedRow(accountId, email.id);
        if (existing != null) {
          final oldJson =
              jsonDecode(await _encryption.decrypt(existing.encryptedData))
                  as Map<String, dynamic>;
          final oldBody = oldJson['body'] as String? ?? '';
          if (oldBody.isNotEmpty) {
            json = {
              ...json,
              'body': oldJson['body'],
              'bodyType': oldJson['bodyType'],
              'attachments': oldJson['attachments'],
              'inlineAttachments': oldJson['inlineAttachments'],
              // Preserve the invite: list/poll fetches carry no ICS, so a
              // thin re-touch would otherwise drop the Accept/Decline banner.
              'meetingInvite': oldJson['meetingInvite'],
              // The attachment metadata just preserved came from the old row,
              // so its parse stamp has to come with it. Stamping a thin
              // re-touch as current would mark stale metadata fresh and
              // silently cancel the one-time repair in
              // [hasStaleAttachmentParse].
              _parseVersionKey: oldJson[_parseVersionKey],
            };
          }
        }
      }

      final encryptedData = await _encryption.encrypt(jsonEncode(json));
      return CachedEmailsCompanion.insert(
        emailId: email.id,
        accountId: accountId,
        folderId: folderId,
        isRead: email.isRead,
        hasAttachments: email.hasAttachments,
        receivedDateTimeMs: email.receivedDateTime.millisecondsSinceEpoch,
        conversationId: Value(email.conversationId),
        cachedAtMs: now,
        encryptedData: encryptedData,
      );
    }));

    Future<void> insertAll() => _database.batch((batch) {
          for (final companion in companions) {
            batch.insert(
              _database.cachedEmails,
              companion,
              mode: InsertMode.insertOrReplace,
            );
          }
        });

    if (!replaceFolder) {
      await insertAll();
      return;
    }

    // The delete runs *after* the preservation lookups above and inside the
    // same transaction as the inserts. Doing it the other way round — the
    // caller clearing the folder and then calling cacheEmails — is what made
    // the preservation above dead code: the lookup found nothing, so every
    // refresh blanked every cached body in the folder and BodyPrefetchService
    // re-downloaded them.
    await _database.transaction(() async {
      await (_database.delete(_database.cachedEmails)
            ..where((t) =>
                t.accountId.equals(accountId) & t.folderId.equals(folderId)))
          .go();
      await insertAll();
    });
  }

  @override
  Future<Email?> getCachedEmailById({
    required String accountId,
    required String emailId,
  }) async {
    final row = await _anyCachedRow(accountId, emailId);
    if (row == null) return null;

    final plaintext = await _encryption.decrypt(row.encryptedData);
    final json = jsonDecode(plaintext) as Map<String, dynamic>;
    return _emailFromJson(json);
  }

  /// Rows [restoreFolderMemberships] must not read a home folder off.
  ///
  /// Gmail's parser names a trashed message's *label* as its parent, because
  /// TRASH and SPAM are system labels it skips — so restoring one would put
  /// deleted mail into a label's cached listing, which is exactly what the
  /// listings exclude. Every other provider files a deleted message under the
  /// same folder its payload names, so it is skipped by the "already there"
  /// test instead and needs no id here. No Graph folder id or IMAP path this
  /// app has seen can collide with these two.
  static const _excludedFromRestore = {'TRASH', 'SPAM'};

  @override
  Future<int> restoreFolderMemberships({required String accountId}) async {
    final rows = await (_database.select(_database.cachedEmails)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    if (rows.isEmpty) return 0;

    // Which folders each message is already filed under. Doubles as the record
    // of what this pass has queued, so a message with several rows — or two
    // rows naming the same home folder — is only added once.
    final filedUnder = <String, Set<String>>{};
    for (final row in rows) {
      (filedUnder[row.emailId] ??= <String>{}).add(row.folderId);
    }

    final additions = <CachedEmailsCompanion>[];
    for (final row in rows) {
      if (_excludedFromRestore.contains(row.folderId)) continue;
      final json = jsonDecode(await _encryption.decrypt(row.encryptedData))
          as Map<String, dynamic>;
      final home = json['parentFolderId'] as String?;
      if (home == null || home.isEmpty) continue;
      if (!filedUnder[row.emailId]!.add(home)) continue;

      // The payload is copied across verbatim: it is the same message, so
      // re-encrypting it would only spend time producing the same row.
      additions.add(CachedEmailsCompanion.insert(
        emailId: row.emailId,
        accountId: accountId,
        folderId: home,
        isRead: row.isRead,
        hasAttachments: row.hasAttachments,
        receivedDateTimeMs: row.receivedDateTimeMs,
        conversationId: Value(row.conversationId),
        cachedAtMs: row.cachedAtMs,
        encryptedData: row.encryptedData,
      ));
    }
    if (additions.isEmpty) return 0;

    await _database.batch((batch) => batch.insertAll(
          _database.cachedEmails,
          additions,
          mode: InsertMode.insertOrIgnore,
        ));
    return additions.length;
  }

  /// One cached copy of [emailId], whichever folder listing it was filed under,
  /// preferring a copy that carries a full body.
  ///
  /// A message appears once per folder it was listed in (see [CachedEmails]),
  /// and every copy holds the same message — so any of them answers "what is
  /// this message". The body is the one thing that can differ, because
  /// [upgradeCachedEmailBody] may not have reached every copy yet.
  Future<CachedEmail?> _anyCachedRow(String accountId, String emailId) async {
    final rows = await (_database.select(_database.cachedEmails)
          ..where(
              (t) => t.accountId.equals(accountId) & t.emailId.equals(emailId)))
        .get();
    if (rows.isEmpty) return null;
    if (rows.length == 1) return rows.first;
    for (final row in rows) {
      final json = jsonDecode(await _encryption.decrypt(row.encryptedData))
          as Map<String, dynamic>;
      if ((json['body'] as String? ?? '').isNotEmpty) return row;
    }
    return rows.first;
  }

  @override
  Future<void> upgradeCachedEmailBody({
    required String accountId,
    required Email email,
  }) async {
    // The encrypt is inside the transaction, unlike cacheEmails' batch — this
    // updates rows that are already there, and doing it beforehand would reopen
    // the very gap the transaction exists to close.
    await _database.transaction(() async {
      final rows = await (_database.select(_database.cachedEmails)
            ..where((t) =>
                t.accountId.equals(accountId) & t.emailId.equals(email.id)))
          .get();
      // Deleted, junked or moved while the body was being fetched. Writing it
      // would put the message the user just got rid of back in the folder.
      if (rows.isEmpty) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      for (final row in rows) {
        // Applied to the entity, not just the column: the row is read back out
        // of the encrypted JSON (see [getCachedEmailById]), so setting the
        // column alone would leave the stale flag as the one the reading pane
        // sees. Per copy, because each folder's row carries its own read state.
        final merged = email.copyWith(isRead: row.isRead);
        final encryptedData =
            await _encryption.encrypt(jsonEncode(_emailToJson(merged)));
        await (_database.update(_database.cachedEmails)
              ..where((t) =>
                  t.accountId.equals(accountId) &
                  t.emailId.equals(email.id) &
                  t.folderId.equals(row.folderId)))
            .write(CachedEmailsCompanion(
              hasAttachments: Value(merged.hasAttachments),
              receivedDateTimeMs:
                  Value(merged.receivedDateTime.millisecondsSinceEpoch),
              conversationId: Value(merged.conversationId),
              cachedAtMs: Value(now),
              encryptedData: Value(encryptedData),
            ));
      }
    });
  }

  @override
  Future<bool> hasStaleAttachmentParse({
    required String accountId,
    required String emailId,
  }) async {
    final row = await _anyCachedRow(accountId, emailId);
    if (row == null) return false;

    final json = jsonDecode(await _encryption.decrypt(row.encryptedData))
        as Map<String, dynamic>;
    final version = json[_parseVersionKey] as int? ?? 1;
    return version < attachmentParseVersion;
  }

  @override
  Future<void> renameCachedEmailId({
    required String accountId,
    required String oldEmailId,
    required String newEmailId,
    required String newFolderId,
  }) async {
    await _database.transaction(() async {
      // The message may be cached under more than one folder; the move collapses
      // every copy into the destination, which is the whole of where it now is.
      final row = await _anyCachedRow(accountId, oldEmailId);
      if (row == null) return;

      final plaintext = await _encryption.decrypt(row.encryptedData);
      final json = jsonDecode(plaintext) as Map<String, dynamic>;
      json['id'] = newEmailId;
      json['parentFolderId'] = newFolderId;
      // The move landed it somewhere else, so its old membership is wrong. This
      // runs for single-folder providers (a move on Graph/IMAP mints a new id),
      // where the destination is the whole of it.
      json['folderIds'] = [newFolderId];
      final encryptedData = await _encryption.encrypt(jsonEncode(json));

      // A row may already exist at newEmailId (e.g. a delta sync landed it
      // first) — clear it so the rename doesn't collide on the primary key.
      await (_database.delete(_database.cachedEmails)
            ..where((t) =>
                t.accountId.equals(accountId) & t.emailId.equals(newEmailId)))
          .go();
      await (_database.delete(_database.cachedEmails)
            ..where((t) =>
                t.accountId.equals(accountId) & t.emailId.equals(oldEmailId)))
          .go();
      await _database.into(_database.cachedEmails).insert(
            CachedEmailsCompanion.insert(
              emailId: newEmailId,
              accountId: accountId,
              folderId: newFolderId,
              isRead: row.isRead,
              hasAttachments: row.hasAttachments,
              receivedDateTimeMs: row.receivedDateTimeMs,
              conversationId: Value(row.conversationId),
              cachedAtMs: DateTime.now().millisecondsSinceEpoch,
              encryptedData: encryptedData,
            ),
          );
    });
  }

  @override
  Future<void> clearCacheForAccount(String accountId) async {
    await (_database.delete(_database.cachedEmails)
          ..where((t) => t.accountId.equals(accountId)))
        .go();
    // The inline cache is keyed by email id alone, so there is no per-account
    // subset to target. Dropping all of it only costs a re-write on next view,
    // and this runs on account removal / an explicit "clear cached mail".
    await _inlineAttachments.clear();
  }

  // Deliberately does not touch the inline attachment cache: EmailListBloc
  // calls this on every successful folder refresh, immediately before writing
  // the fresh page back, so evicting here would throw the images away on each
  // poll. Genuinely removed emails come through deleteEmailFromCache; anything
  // else is caught by InlineAttachmentCache.prune on startup.
  @override
  Future<void> clearCacheForFolder({
    required String accountId,
    required String folderId,
  }) async {
    await (_database.delete(_database.cachedEmails)
          ..where((t) => t.accountId.equals(accountId) & t.folderId.equals(folderId)))
        .go();
  }

  @override
  Future<void> deleteEmailFromCache({
    required String accountId,
    required String emailId,
    bool evictInlineAttachments = true,
  }) async {
    await (_database.delete(_database.cachedEmails)
          ..where((t) => t.accountId.equals(accountId) & t.emailId.equals(emailId)))
        .go();
    if (evictInlineAttachments) {
      await _inlineAttachments.evictEmail(emailId);
    }
  }

  @override
  Future<void> updateEmailReadStatusInCache({
    required String accountId,
    required String emailId,
    required bool isRead,
  }) async {
    final rows = await (_database.select(_database.cachedEmails)
          ..where((t) => t.accountId.equals(accountId) & t.emailId.equals(emailId)))
        .get();
    if (rows.isEmpty) return;

    final plaintext = await _encryption.decrypt(rows.first.encryptedData);
    final json = jsonDecode(plaintext) as Map<String, dynamic>;
    json['isRead'] = isRead;
    final encryptedData = await _encryption.encrypt(jsonEncode(json));

    await (_database.update(_database.cachedEmails)
          ..where((t) => t.accountId.equals(accountId) & t.emailId.equals(emailId)))
        .write(CachedEmailsCompanion(
          isRead: Value(isRead),
          encryptedData: Value(encryptedData),
        ));
  }

  @override
  Future<void> updateCachedEmailFields({
    required String accountId,
    required String emailId,
    bool? isRead,
    bool? isFlagged,
  }) async {
    if (isRead == null && isFlagged == null) return;

    // Any copy answers for the message, and the write below covers all of them.
    final row = await _anyCachedRow(accountId, emailId);
    if (row == null) return;

    final json = jsonDecode(await _encryption.decrypt(row.encryptedData))
        as Map<String, dynamic>;
    if (isRead != null) json['isRead'] = isRead;
    if (isFlagged != null) json['isFlagged'] = isFlagged;
    final encryptedData = await _encryption.encrypt(jsonEncode(json));

    await (_database.update(_database.cachedEmails)
          ..where(
              (t) => t.accountId.equals(accountId) & t.emailId.equals(emailId)))
        .write(CachedEmailsCompanion(
          // isFlagged has no column of its own — it is read back out of the
          // encrypted payload — so only isRead is mirrored here.
          isRead: isRead == null ? const Value.absent() : Value(isRead),
          encryptedData: Value(encryptedData),
        ));
  }

  // ---------------------------------------------------------------------------
  // Serialisation helpers
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _emailToJson(Email email) {
    return {
      'id': email.id,
      'subject': email.subject,
      'from': _addressToJson(email.from),
      'toRecipients': email.toRecipients.map(_addressToJson).toList(),
      'ccRecipients': email.ccRecipients.map(_addressToJson).toList(),
      'bodyPreview': email.bodyPreview,
      'body': email.body,
      'bodyType': email.bodyType == EmailBodyType.html ? 'html' : 'text',
      'isRead': email.isRead,
      'isFlagged': email.isFlagged,
      'receivedDateTime': email.receivedDateTime.toIso8601String(),
      'sentDateTime': email.sentDateTime?.toIso8601String(),
      'importance': switch (email.importance) {
        EmailImportance.low => 'low',
        EmailImportance.high => 'high',
        EmailImportance.normal => 'normal',
      },
      'conversationId': email.conversationId,
      'hasAttachments': email.hasAttachments,
      'attachments': email.attachments.map(_attachmentToJson).toList(),
      'inlineAttachments':
          email.inlineAttachments.map(_inlineAttachmentToJson).toList(),
      'parentFolderId': email.parentFolderId,
      'folderIds': email.folderIds,
      'meetingInvite': _meetingInviteToJson(email.meetingInvite),
      _parseVersionKey: attachmentParseVersion,
    };
  }

  static Map<String, dynamic>? _meetingInviteToJson(MeetingInvite? invite) {
    if (invite == null) return null;
    return {
      'icsData': invite.icsData,
      'uid': invite.uid,
      'summary': invite.summary,
      'description': invite.description,
      'meetingStart': invite.meetingStart?.toIso8601String(),
      'meetingEnd': invite.meetingEnd?.toIso8601String(),
      'location': invite.location,
      'isAllDay': invite.isAllDay,
      'type': invite.type.name,
      'proposedStart': invite.proposedStart?.toIso8601String(),
      'proposedEnd': invite.proposedEnd?.toIso8601String(),
    };
  }

  static MeetingInvite? _meetingInviteFromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final start = j['meetingStart'] as String?;
    final end = j['meetingEnd'] as String?;
    final proposedStart = j['proposedStart'] as String?;
    final proposedEnd = j['proposedEnd'] as String?;
    return MeetingInvite(
      icsData: j['icsData'] as String?,
      uid: j['uid'] as String?,
      summary: j['summary'] as String?,
      description: j['description'] as String?,
      meetingStart: start != null ? DateTime.parse(start) : null,
      meetingEnd: end != null ? DateTime.parse(end) : null,
      location: j['location'] as String?,
      isAllDay: j['isAllDay'] as bool? ?? false,
      type: MeetingEmailType.values.byName(
        j['type'] as String? ?? MeetingEmailType.invitation.name,
      ),
      proposedStart:
          proposedStart != null ? DateTime.tryParse(proposedStart) : null,
      proposedEnd: proposedEnd != null ? DateTime.tryParse(proposedEnd) : null,
    );
  }

  static Email _emailFromJson(Map<String, dynamic> j) {
    return Email(
      id: j['id'] as String,
      subject: j['subject'] as String,
      from: _addressFromJson(j['from'] as Map<String, dynamic>),
      toRecipients: (j['toRecipients'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(_addressFromJson)
          .toList(),
      ccRecipients: (j['ccRecipients'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(_addressFromJson)
          .toList(),
      bodyPreview: j['bodyPreview'] as String,
      body: j['body'] as String,
      bodyType:
          j['bodyType'] == 'html' ? EmailBodyType.html : EmailBodyType.text,
      isRead: j['isRead'] as bool,
      // Absent on rows cached before the flag was recorded — not flagged is the
      // honest answer, and the next sync of that message fills it in.
      isFlagged: j['isFlagged'] as bool? ?? false,
      receivedDateTime: DateTime.parse(j['receivedDateTime'] as String),
      sentDateTime: j['sentDateTime'] != null
          ? DateTime.parse(j['sentDateTime'] as String)
          : null,
      importance: switch (j['importance'] as String?) {
        'low' => EmailImportance.low,
        'high' => EmailImportance.high,
        _ => EmailImportance.normal,
      },
      conversationId: j['conversationId'] as String?,
      hasAttachments: j['hasAttachments'] as bool? ?? false,
      // Null-safe like inlineAttachments below: a legacy row cached before the
      // attachments field existed, or a preservation merge that copied through
      // a null, has no 'attachments' key. A bare `as List` would throw here —
      // and this runs inside getCachedEmailById, outside getEmail's try, so
      // the whole message would fail to load instead of just missing chips.
      attachments: (j['attachments'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(_attachmentFromJson)
          .toList(),
      inlineAttachments: (j['inlineAttachments'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(_inlineAttachmentFromJson)
          .whereType<InlineAttachment>()
          .toList(),
      parentFolderId: j['parentFolderId'] as String?,
      // Absent on rows cached before folder membership was recorded; an empty
      // list is the honest answer there and sends readers to the
      // parentFolderId fallback rather than claiming the message is nowhere.
      folderIds: (j['folderIds'] as List<dynamic>? ?? const []).cast<String>(),
      meetingInvite:
          _meetingInviteFromJson(j['meetingInvite'] as Map<String, dynamic>?),
    );
  }

  static Map<String, dynamic> _addressToJson(EmailAddress a) => {
        'address': a.address,
        'name': a.name,
      };

  static EmailAddress _addressFromJson(Map<String, dynamic> j) =>
      EmailAddress(address: j['address'] as String, name: j['name'] as String?);

  static Map<String, dynamic> _attachmentToJson(EmailAttachment a) => {
        'id': a.id,
        'name': a.name,
        'contentType': a.contentType,
        'size': a.size,
      };

  static EmailAttachment _attachmentFromJson(Map<String, dynamic> j) =>
      EmailAttachment(
        id: j['id'] as String,
        name: j['name'] as String,
        contentType: j['contentType'] as String,
        size: j['size'] as int,
      );

  static Map<String, dynamic> _inlineAttachmentToJson(InlineAttachment a) => {
        'contentId': a.contentId,
        'contentType': a.contentType,
        'bytes': base64Encode(a.contentBytes),
      };

  static InlineAttachment? _inlineAttachmentFromJson(Map<String, dynamic> j) {
    final contentId = j['contentId'] as String?;
    final bytes = j['bytes'] as String?;
    if (contentId == null || bytes == null) return null;
    try {
      return InlineAttachment(
        contentId: contentId,
        contentType: j['contentType'] as String? ?? 'application/octet-stream',
        contentBytes: base64Decode(bytes),
      );
    } catch (_) {
      return null;
    }
  }
}
