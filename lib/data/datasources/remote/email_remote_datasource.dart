import 'dart:typed_data';

import '../../../core/utils/special_folder_kind.dart';
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
    List<String> ccAddresses = const [],
    required String comment,
    List<String> excludedAttachmentIds = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  });

  /// Moves [id] to [destinationFolderId]. Returns the message's new id when
  /// the server assigns one (Graph and IMAP both mint a new id/UID on a
  /// folder move; Gmail's ids are stable across label changes so it may
  /// return the same id), or null if the server response doesn't include it
  /// — callers that need to keep referencing this message afterward (e.g.
  /// the outbox drain engine) must treat a non-null differing id as a rename.
  Future<String?> moveEmail(String id, String destinationFolderId);

  /// Reports [id] as junk (moves it to the junk folder). Same new-id
  /// semantics as [moveEmail].
  Future<String?> reportJunk(String id);

  Future<void> deleteEmail(String id);

  /// Empties all emails from [folderId].
  /// If [permanentDelete] is true, messages are irrecoverably deleted;
  /// otherwise they are moved to the trash/deleted-items folder.
  Future<void> emptyFolder(String folderId, {bool permanentDelete = false});

  Future<Uint8List> downloadAttachment(String messageId, String attachmentId);

  /// Returns the raw RFC 822 MIME bytes for [id].
  Future<Uint8List> getRawEmailBytes(String id);

  /// Creates a new child folder under [parentFolderId] with [displayName]
  /// and returns its id. If a folder with that name already exists under
  /// the parent, returns the existing folder's id rather than erroring —
  /// callers (notably account migration, which calls this on every resume)
  /// must be able to treat "already exists" as success.
  Future<String> createFolder({
    required String parentFolderId,
    required String displayName,
  });

  /// Resolves this account's special-use folders (inbox/sent/trash/junk/
  /// archive) to their folder ids. A kind this provider has no distinct
  /// folder for (e.g. Gmail has no separate Archive) is omitted from the map
  /// rather than guessed at.
  Future<Map<SpecialFolderKind, String>> getSpecialFolderIds();

  /// Inserts a complete RFC 822 message ([rawBytes]) into [folderId] without
  /// sending it — used by account migration to copy mail history rather than
  /// replaying it through drafts/send. [receivedAt] and [isRead] are applied
  /// where the provider allows; a provider whose "create message" API takes
  /// structured fields rather than raw MIME (Graph) parses [rawBytes] itself
  /// to recover them, keeping that translation a data-layer concern rather
  /// than something callers need to know about. Returns the new message's id.
  ///
  /// Byte-exactness is a per-provider property, not a guarantee of this
  /// interface: IMAP and Gmail write [rawBytes] unchanged. Graph cannot —
  /// there is no raw-MIME create endpoint — so it is rebuilt from the parsed
  /// fields, and its structured `from` is dropped rather than the whole
  /// insert failing when the signed-in account has no SendAs right over the
  /// original sender (the copy still lands, just attributed to whoever is
  /// signed in).
  Future<String> insertRawMessage({
    required String folderId,
    required Uint8List rawBytes,
    required DateTime receivedAt,
    required bool isRead,
  });

  /// Renames [folderId] to [newDisplayName].
  Future<void> renameFolder({
    required String folderId,
    required String newDisplayName,
  });

  /// Reparents [folderId] so it becomes a child of [newParentFolderId].
  /// Any sub-folders of [folderId] move with it.
  /// Reparents [folderId] under [newParentFolderId], and returns the folder's
  /// id **after** the move — which is not always the one that went in: an id
  /// that encodes a path (IMAP mailbox, Gmail virtual folder) changes with the
  /// path. Graph and real Gmail labels keep theirs.
  Future<String> moveFolder({
    required String folderId,
    required String newParentFolderId,
  });

  /// Searches [folderId] (and its immediate children where supported) for
  /// emails matching [query].  Supports `from:`, `to:`, `subject:`, and
  /// `has:attachment` notation.  Results are NOT cached.
  Future<List<EmailModel>> searchEmails({
    String? folderId,
    required String query,
    int top = 50,
  });

  /// Returns every message belonging to [conversationId], across all folders
  /// where the provider supports it. Results are NOT cached.
  ///
  /// [folderId] is only a hint for providers whose thread lookup is inherently
  /// folder-scoped (IMAP, which has no thread API and matches on the
  /// normalized subject). Graph and Gmail have real conversation/thread
  /// endpoints and search the whole mailbox regardless.
  Future<List<EmailModel>> getConversationMessages(
    String conversationId, {
    String? folderId,
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
