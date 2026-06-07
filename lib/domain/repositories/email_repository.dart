import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/email.dart';
import '../entities/email_folder.dart';

abstract interface class EmailRepository {
  /// Fetches a page of emails from [folderId] (defaults to inbox).
  Future<Either<Failure, List<Email>>> getEmails({
    String? folderId,
    int top = 25,
    int skip = 0,
    String? filter,
    String orderBy = 'receivedDateTime desc',
  });

  /// Fetches a single email by [id] with full body content.
  Future<Either<Failure, Email>> getEmail(String id);

  /// Marks an email as read or unread.
  Future<Either<Failure, Email>> markAsRead({
    required String id,
    required bool isRead,
  });

  /// Lists all mail folders for the current user.
  Future<Either<Failure, List<EmailFolder>>> getMailFolders();

  /// Lists child folders of [parentFolderId].
  Future<Either<Failure, List<EmailFolder>>> getChildFolders(
      String parentFolderId);

  /// Sends a new email.
  Future<Either<Failure, Unit>> sendEmail({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
  });

  /// Replies to an existing email. Set [replyAll] to reply to all recipients.
  Future<Either<Failure, Unit>> replyToEmail({
    required String messageId,
    required String comment,
    bool replyAll = false,
  });

  /// Forwards an existing email.
  Future<Either<Failure, Unit>> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    required String comment,
  });

  /// Deletes (moves to Deleted Items) an email by [id].
  Future<Either<Failure, Unit>> deleteEmail(String id);

  /// Downloads the raw bytes of a file attachment.
  Future<Either<Failure, Uint8List>> downloadAttachment({
    required String messageId,
    required String attachmentId,
  });
}
