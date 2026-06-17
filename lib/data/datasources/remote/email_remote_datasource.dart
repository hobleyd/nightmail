import 'dart:typed_data';

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
  });

  Future<void> replyToEmail({
    required String messageId,
    required String comment,
    bool replyAll = false,
  });

  Future<void> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    required String comment,
    List<String> excludedAttachmentIds = const [],
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
}
