import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../domain/entities/email.dart';
import '../../../domain/entities/email_address.dart';
import '../../../domain/entities/email_attachment.dart';
import '../../database/app_database.dart';
import '../../../infrastructure/cache/cache_encryption_service.dart';
import 'email_local_datasource.dart';

class EmailLocalDatasourceImpl implements EmailLocalDatasource {
  const EmailLocalDatasourceImpl({
    required this._database,
    required this._encryption,
  });

  final AppDatabase _database;
  final CacheEncryptionService _encryption;

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
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // Encrypt all emails concurrently before opening the batch transaction
    final companions = await Future.wait(emails.map((email) async {
      final encryptedData =
          await _encryption.encrypt(jsonEncode(_emailToJson(email)));
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

    await _database.batch((batch) {
      for (final companion in companions) {
        batch.insert(
          _database.cachedEmails,
          companion,
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  @override
  Future<Email?> getCachedEmailById({
    required String accountId,
    required String emailId,
  }) async {
    final row = await (_database.select(_database.cachedEmails)
          ..where((t) => t.accountId.equals(accountId) & t.emailId.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return null;

    final plaintext = await _encryption.decrypt(row.encryptedData);
    final json = jsonDecode(plaintext) as Map<String, dynamic>;
    return _emailFromJson(json);
  }

  @override
  Future<void> clearCacheForAccount(String accountId) async {
    await (_database.delete(_database.cachedEmails)
          ..where((t) => t.accountId.equals(accountId)))
        .go();
  }

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
  }) async {
    await (_database.delete(_database.cachedEmails)
          ..where((t) => t.accountId.equals(accountId) & t.emailId.equals(emailId)))
        .go();
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
      'parentFolderId': email.parentFolderId,
    };
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
      hasAttachments: j['hasAttachments'] as bool,
      attachments: (j['attachments'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(_attachmentFromJson)
          .toList(),
      parentFolderId: j['parentFolderId'] as String?,
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
}
