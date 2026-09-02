import 'dart:convert';
import 'dart:typed_data';

import '../../core/utils/html_entities.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_attachment.dart';
import '../../domain/entities/inline_attachment.dart';
import '../../domain/entities/meeting_invite.dart';
import 'email_address_model.dart';

class EmailModel extends Email {
  const EmailModel({
    required super.id,
    required super.subject,
    required super.from,
    required super.toRecipients,
    required super.ccRecipients,
    required super.bodyPreview,
    required super.body,
    required super.bodyType,
    required super.isRead,
    required super.receivedDateTime,
    required super.importance,
    super.isFlagged,
    super.sentDateTime,
    super.conversationId,
    super.hasAttachments,
    super.attachments,
    super.inlineAttachments,
    super.parentFolderId,
    super.folderIds,
    super.meetingInvite,
  });

  factory EmailModel.fromJson(Map<String, dynamic> json) {
    final bodyMap = json['body'] as Map<String, dynamic>?;
    final bodyContent = bodyMap?['content'] as String? ?? '';
    final bodyTypeStr = bodyMap?['contentType'] as String? ?? 'text';
    final parentFolderId = json['parentFolderId'] as String?;

    return EmailModel(
      id: json['id'] as String,
      subject: decodeHtmlEntities(json['subject'] as String? ?? '(No Subject)'),
      from: EmailAddressModel.fromJson(
        json['from'] as Map<String, dynamic>? ?? {},
      ),
      toRecipients: (json['toRecipients'] as List<dynamic>? ?? [])
          .map((r) => EmailAddressModel.fromJson(r as Map<String, dynamic>))
          .toList(),
      ccRecipients: (json['ccRecipients'] as List<dynamic>? ?? [])
          .map((r) => EmailAddressModel.fromJson(r as Map<String, dynamic>))
          .toList(),
      bodyPreview: decodeHtmlEntities(json['bodyPreview'] as String? ?? ''),
      body: bodyContent,
      bodyType: bodyTypeStr == 'html' ? EmailBodyType.html : EmailBodyType.text,
      isRead: json['isRead'] as bool? ?? false,
      isFlagged: _parseGraphFlag(json['flag']),
      // Some delta-sync items (e.g. transient system-generated messages)
      // arrive without receivedDateTime populated yet — falling back instead
      // of throwing keeps one such item from discarding an entire poll's
      // worth of otherwise-valid results.
      receivedDateTime: DateTime.tryParse(
            json['receivedDateTime'] as String? ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      sentDateTime: json['sentDateTime'] != null
          ? DateTime.tryParse(json['sentDateTime'] as String)
          : null,
      importance: _parseImportance(json['importance'] as String?),
      conversationId: json['conversationId'] as String?,
      hasAttachments: json['hasAttachments'] as bool? ?? false,
      attachments: _parseAttachments(json['attachments']),
      inlineAttachments: _parseInlineAttachments(json['attachments']),
      parentFolderId: parentFolderId,
      // A Graph message lives in exactly one folder, so its parent id *is* its
      // whole membership. Stating it explicitly keeps folder-scoped actions off
      // the [parentFolderId] fallback path.
      folderIds: parentFolderId == null ? const [] : [parentFolderId],
      meetingInvite: _parseMeetingInvite(
        json['@odata.type'] as String?,
        json['meetingMessageType'] as String?,
        json,
      ),
    );
  }

  /// Graph reports the flag as `flag: {flagStatus: notFlagged|flagged|complete}`.
  ///
  /// `complete` is a *cleared* follow-up, not a live one, so only `flagged`
  /// counts. An absent `flag` object means the projection did not ask for it —
  /// read as not flagged rather than throwing, the same way every other optional
  /// field here degrades.
  static bool _parseGraphFlag(dynamic raw) {
    if (raw is! Map<String, dynamic>) return false;
    return (raw['flagStatus'] as String?)?.toLowerCase() == 'flagged';
  }

  static List<EmailAttachment> _parseAttachments(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .cast<Map<String, dynamic>>()
        .where((a) => a['isInline'] != true)
        .map((a) {
          final embedded = _isEmbeddedMessage(a);
          final name = a['name'] as String? ?? 'Attachment';
          return EmailAttachment(
            id: a['id'] as String? ?? '',
            name: embedded ? _emlFileName(name) : name,
            contentType: embedded
                ? 'message/rfc822'
                : a['contentType'] as String? ?? 'application/octet-stream',
            size: a['size'] as int? ?? 0,
          );
        })
        .toList();
  }

  /// Whether an attachment is an email attached to this one.
  ///
  /// Outlook's "attach an email" produces a `#microsoft.graph.itemAttachment`,
  /// which is not a file: it carries no `contentBytes`, and its `name` is the
  /// attached message's *subject*, so it arrives with no extension to read a
  /// type off. Left alone it got no preview and no icon, and downloading it
  /// failed outright — see `GraphApiDatasourceImpl.downloadAttachment`, which
  /// falls back to `/$value` for exactly this subtype.
  ///
  /// Deliberately matched on either signal and widened no further. Graph
  /// omits `@odata.type` from a `$select`ed projection, and which of the two
  /// shapes it answers with here is not something this code can assume — but
  /// an attachment Graph merely declined to *type* must not be claimed, or a
  /// file with no `contentType` gets offered as an email, parses to an empty
  /// one, and loses the open-externally behaviour that works today. Silently
  /// not previewing is the better wrong answer.
  static bool _isEmbeddedMessage(Map<String, dynamic> a) {
    final odataType = (a['@odata.type'] as String? ?? '').toLowerCase();
    if (odataType.contains('itemattachment')) return true;
    return (a['contentType'] as String? ?? '')
        .toLowerCase()
        .contains('rfc822');
  }

  /// `<subject>.eml`. The extension is what makes a saved attached message open
  /// as mail rather than as nothing, and what the reading pane's chip reads to
  /// offer the preview. Mirrors the IMAP path's `_forwardedMessageName`,
  /// including its 120-character cap: a subject runs to any length and a file
  /// name is not the place to find that out.
  static String _emlFileName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Attached message.eml';
    if (trimmed.toLowerCase().endsWith('.eml')) return trimmed;
    final capped = trimmed.length > 120 ? trimmed.substring(0, 120) : trimmed;
    return '$capped.eml';
  }

  static List<InlineAttachment> _parseInlineAttachments(dynamic raw) {
    if (raw is! List) return const [];
    final result = <InlineAttachment>[];
    for (final a in raw.cast<Map<String, dynamic>>()) {
      if (a['isInline'] != true) continue;
      final contentId = a['contentId'] as String?;
      final contentBytesStr = a['contentBytes'] as String?;
      if (contentId == null || contentId.isEmpty) continue;
      if (contentBytesStr == null || contentBytesStr.isEmpty) continue;
      final Uint8List bytes;
      try {
        bytes = base64Decode(contentBytesStr);
      } catch (_) {
        continue;
      }
      result.add(InlineAttachment(
        contentId: contentId,
        contentType: a['contentType'] as String? ?? 'application/octet-stream',
        contentBytes: bytes,
      ));
    }
    return result;
  }

  static MeetingInvite? _parseMeetingInvite(
      String? odataType, String? meetingMessageType, Map<String, dynamic> json) {
    // Only surface invite/cancellation UI for relevant message types.
    // Exclude acceptance/tentative notifications (others responding to us).
    var type = switch (meetingMessageType) {
      'meetingRequest' => MeetingEmailType.invitation,
      'meetingCancelled' => MeetingEmailType.cancellation,
      'meetingDeclined' => MeetingEmailType.declineNotification,
      _ => null,
    };
    if (type == null) return null;

    final meetingStart = _parseGraphDateTime(json['startDateTime']);
    final meetingEnd = _parseGraphDateTime(json['endDateTime']);

    // A propose-new-time arrives as a decline carrying `proposedNewTime`
    // (a timeSlot). Only reclassify when the slot actually parses: a decline
    // whose proposal we cannot read is still an ordinary decline, and must keep
    // offering "Cancel meeting" rather than an Accept button with no time.
    final slot = json['proposedNewTime'] as Map<String, dynamic>?;
    final proposedStart = _parseGraphDateTime(slot?['start']);
    final proposedEnd = _parseGraphDateTime(slot?['end']);
    if (type == MeetingEmailType.declineNotification &&
        proposedStart != null &&
        proposedEnd != null) {
      type = MeetingEmailType.proposedNewTime;
    }

    String? location;
    final locationMap = json['location'] as Map<String, dynamic>?;
    final locationName = locationMap?['displayName'] as String?;
    if (locationName != null && locationName.isNotEmpty) location = locationName;

    final isAllDay = json['isAllDay'] as bool? ?? false;

    return MeetingInvite(
      meetingStart: meetingStart,
      meetingEnd: meetingEnd,
      location: location,
      isAllDay: isAllDay,
      type: type,
      proposedStart: proposedStart,
      proposedEnd: proposedEnd,
    );
  }

  /// Parses a Graph `DateTimeTimeZone` (`{dateTime, timeZone}`) as UTC.
  ///
  /// getEmail() sends `Prefer: outlook.timezone="UTC"`, so Graph returns the
  /// dateTime string already in UTC but without a Z suffix — append one so
  /// DateTime.parse does not read it as local time.
  static DateTime? _parseGraphDateTime(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final str = raw['dateTime'] as String?;
    if (str == null || str.isEmpty) return null;
    return DateTime.tryParse(str.endsWith('Z') ? str : '${str}Z');
  }

  static EmailImportance _parseImportance(String? value) {
    return switch (value?.toLowerCase()) {
      'low' => EmailImportance.low,
      'high' => EmailImportance.high,
      _ => EmailImportance.normal,
    };
  }

  factory EmailModel.fromEntity(Email entity) {
    return EmailModel(
      id: entity.id,
      subject: entity.subject,
      from: EmailAddressModel.fromEntity(entity.from),
      toRecipients: entity.toRecipients
          .map(EmailAddressModel.fromEntity)
          .toList(),
      ccRecipients: entity.ccRecipients
          .map(EmailAddressModel.fromEntity)
          .toList(),
      bodyPreview: entity.bodyPreview,
      body: entity.body,
      bodyType: entity.bodyType,
      isRead: entity.isRead,
      isFlagged: entity.isFlagged,
      receivedDateTime: entity.receivedDateTime,
      sentDateTime: entity.sentDateTime,
      importance: entity.importance,
      conversationId: entity.conversationId,
      hasAttachments: entity.hasAttachments,
      attachments: entity.attachments,
      inlineAttachments: entity.inlineAttachments,
      parentFolderId: entity.parentFolderId,
      folderIds: entity.folderIds,
      meetingInvite: entity.meetingInvite,
    );
  }
}
