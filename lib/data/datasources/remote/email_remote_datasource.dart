import 'dart:typed_data';

import '../../../domain/entities/email.dart';
import '../../../domain/entities/local_attachment.dart';
import '../../models/email_folder_model.dart';
import '../../models/email_model.dart';

abstract interface class EmailRemoteDatasource {
  Future<List<EmailModel>> getEmails({
    String? folderId,
    int top = 25,
    int skip = 0,
    String? filter,
    String orderBy = 'receivedDateTime desc',
  });

  Future<EmailModel> getEmail(String id);

  Future<EmailModel> updateEmailReadStatus({
    required String id,
    required bool isRead,
  });

  Future<List<EmailFolderModel>> getMailFolders();

  Future<List<EmailFolderModel>> getChildFolders(String parentFolderId);

  Future<void> sendEmail({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  });

  Future<void> replyToEmail({
    required String messageId,
    required String comment,
    bool replyAll = false,
    List<String> toAddresses = const [],
    List<String> ccAddresses = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  });

  Future<void> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    required String comment,
    List<String> excludedAttachmentIds = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  });

  Future<void> moveEmail(String id, String destinationFolderId);

  Future<void> reportJunk(String id);

  Future<void> deleteEmail(String id);

  /// Empties all emails from [folderId].
  /// If [permanentDelete] is true, messages are irrecoverably deleted;
  /// otherwise they are moved to the trash/deleted-items folder.
  Future<void> emptyFolder(String folderId, {bool permanentDelete = false});

  Future<Uint8List> downloadAttachment(String messageId, String attachmentId);

  /// Returns the raw RFC 822 MIME bytes for [id].
  Future<Uint8List> getRawEmailBytes(String id);

  /// Creates a new child folder under [parentFolderId] with [displayName].
  Future<void> createFolder({
    required String parentFolderId,
    required String displayName,
  });

  /// Renames [folderId] to [newDisplayName].
  Future<void> renameFolder({
    required String folderId,
    required String newDisplayName,
  });

  /// Searches [folderId] (and its immediate children where supported) for
  /// emails matching [query].  Supports `from:`, `to:`, `subject:`, and
  /// `has:attachment` notation.  Results are NOT cached.
  Future<List<EmailModel>> searchEmails({
    String? folderId,
    required String query,
    int top = 50,
  });

  /// Creates a server-side draft and returns its server-assigned draft ID.
  Future<String> createServerDraft({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  });

  /// Updates an existing draft. Returns the (possibly new) draft ID.
  Future<String> updateServerDraft({
    required String draftId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  });

  /// Permanently deletes a server draft by [draftId].
  Future<void> deleteServerDraft({required String draftId});
}
