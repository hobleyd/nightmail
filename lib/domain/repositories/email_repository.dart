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
    List<String> excludedAttachmentIds = const [],
  });

  /// Moves an email to [destinationFolderId].
  Future<Either<Failure, Unit>> moveEmail(
      String id, String destinationFolderId);

  /// Reports [id] as junk/spam.
  Future<Either<Failure, Unit>> reportJunk(String id);

  /// Deletes (moves to Deleted Items) an email by [id].
  Future<Either<Failure, Unit>> deleteEmail(String id);

  /// Empties all emails from [folderId].
  /// If [permanentDelete] is true, messages are irrecoverably deleted;
  /// otherwise they are moved to trash/deleted-items.
  Future<Either<Failure, Unit>> emptyFolder(
    String folderId, {
    bool permanentDelete = false,
  });

  /// Downloads the raw bytes of a file attachment.
  Future<Either<Failure, Uint8List>> downloadAttachment({
    required String messageId,
    required String attachmentId,
  });

  /// Returns locally cached folder list for [accountId].
  /// Returns an empty list when no cache exists — never fails on cache absence.
  Future<Either<Failure, List<EmailFolder>>> getCachedFolders(String accountId);

  /// Returns locally cached emails for [accountId]/[folderId].
  /// Returns an empty list when no cache exists — never fails on cache absence.
  Future<Either<Failure, List<Email>>> getCachedEmails({
    required String accountId,
    required String folderId,
  });

  /// Writes [emails] to the local cache for [accountId]/[folderId].
  Future<Either<Failure, Unit>> cacheEmails({
    required String accountId,
    required String folderId,
    required List<Email> emails,
  });

  /// Deletes all cached emails belonging to [accountId].
  Future<Either<Failure, Unit>> clearCacheForAccount(String accountId);

  /// Returns the raw RFC 822 MIME bytes for the email with [id].
  Future<Either<Failure, Uint8List>> getRawEmailBytes(String id);

  /// Creates a new child folder under [parentFolderId] with [displayName].
  Future<Either<Failure, Unit>> createFolder({
    required String parentFolderId,
    required String displayName,
  });

  /// Searches [folderId] (and its immediate children where supported) for
  /// emails matching [query].  Supports `from:`, `to:`, `subject:`, and
  /// `has:attachment` notation.  Results are NOT cached.
  Future<Either<Failure, List<Email>>> searchEmails({
    String? folderId,
    required String query,
    int top = 50,
  });
}
