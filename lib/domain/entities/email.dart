import 'package:equatable/equatable.dart';
import 'email_address.dart';
import 'email_attachment.dart';
import 'inline_attachment.dart';
import 'meeting_invite.dart';

enum EmailBodyType { text, html }

enum EmailImportance { low, normal, high }

/// Gmail's stable well-known label ids for Sent and Drafts. They are the only
/// provider ids that need naming here: Gmail is the one backend that reports a
/// message in several folders at once, so it is the one where "is this just the
/// sent copy?" cannot be answered by folder membership alone.
const _sentLabelIds = {'SENT', 'DRAFT'};

class Email extends Equatable {
  const Email({
    required this.id,
    required this.subject,
    required this.from,
    required this.toRecipients,
    required this.ccRecipients,
    required this.bodyPreview,
    required this.body,
    required this.bodyType,
    required this.isRead,
    required this.receivedDateTime,
    required this.importance,
    this.sentDateTime,
    this.conversationId,
    this.hasAttachments = false,
    this.attachments = const [],
    this.inlineAttachments = const [],
    this.parentFolderId,
    this.folderIds = const [],
    this.meetingInvite,
  });

  final String id;
  final String subject;
  final EmailAddress from;
  final List<EmailAddress> toRecipients;
  final List<EmailAddress> ccRecipients;
  final String bodyPreview;
  final String body;
  final EmailBodyType bodyType;
  final bool isRead;
  final DateTime receivedDateTime;
  final DateTime? sentDateTime;
  final EmailImportance importance;
  final String? conversationId;
  final bool hasAttachments;
  final List<EmailAttachment> attachments;
  final List<InlineAttachment> inlineAttachments;
  final String? parentFolderId;

  /// Every folder this message belongs to, when the provider reports it.
  ///
  /// Gmail labels are many-to-many — one message can be in INBOX, SENT and a
  /// user label at once — which a single [parentFolderId] cannot express.
  /// Empty means "not reported": IMAP and legacy cache rows fall back to
  /// [parentFolderId]. See [isInFolder].
  final List<String> folderIds;

  final MeetingInvite? meetingInvite;

  /// Whether this message physically lives in [folderId].
  ///
  /// Used to decide which members of a conversation a folder-scoped action may
  /// touch: Graph and Gmail both surface a thread's other-folder messages
  /// (already-filed replies, the copies in Sent) inside a folder listing, and
  /// those must be left alone.
  ///
  /// A null [folderId] means the view is not scoped to a folder, so everything
  /// counts. When [folderIds] is empty the message came from a provider that
  /// does not report membership, so [parentFolderId] decides — and a null
  /// [parentFolderId] means it came straight from the folder query, since
  /// cross-folder additions always carry a real one.
  bool isInFolder(String? folderId) {
    if (folderId == null) return true;
    if (folderIds.isNotEmpty) return folderIds.contains(folderId);
    return parentFolderId == null || parentFolderId == folderId;
  }

  /// Whether a delete scoped to [folderId] is allowed to remove this message.
  ///
  /// [isInFolder], plus a guard for the copy of a message that lives in Sent or
  /// Drafts: on Gmail the same message can carry SENT *and* the label being
  /// viewed, and deleting a thread out of the Inbox must never take the record
  /// of what was sent with it. Graph and IMAP put a message in exactly one
  /// folder, so for them [isInFolder] has already ruled those out.
  ///
  /// Viewing Sent or Drafts itself, or an unscoped view (search, thread focus),
  /// lifts the guard — there the messages are what the user is looking at.
  bool isDeletableFrom(String? folderId) {
    if (!isInFolder(folderId)) return false;
    if (folderId == null || _sentLabelIds.contains(folderId)) return true;
    return !folderIds.any(_sentLabelIds.contains);
  }

  Email copyWith({bool? isRead}) {
    return Email(
      id: id,
      subject: subject,
      from: from,
      toRecipients: toRecipients,
      ccRecipients: ccRecipients,
      bodyPreview: bodyPreview,
      body: body,
      bodyType: bodyType,
      isRead: isRead ?? this.isRead,
      receivedDateTime: receivedDateTime,
      sentDateTime: sentDateTime,
      importance: importance,
      conversationId: conversationId,
      hasAttachments: hasAttachments,
      attachments: attachments,
      inlineAttachments: inlineAttachments,
      parentFolderId: parentFolderId,
      folderIds: folderIds,
      meetingInvite: meetingInvite,
    );
  }

  @override
  List<Object?> get props => [
        id,
        subject,
        from,
        toRecipients,
        ccRecipients,
        bodyPreview,
        isRead,
        receivedDateTime,
        sentDateTime,
        importance,
        conversationId,
        hasAttachments,
        attachments,
        parentFolderId,
        folderIds,
      ];
}
