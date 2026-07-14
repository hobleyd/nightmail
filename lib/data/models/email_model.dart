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
    super.sentDateTime,
    super.conversationId,
    super.hasAttachments,
    super.attachments,
    super.inlineAttachments,
    super.parentFolderId,
    super.meetingInvite,
  });

  factory EmailModel.fromJson(Map<String, dynamic> json) {
    final bodyMap = json['body'] as Map<String, dynamic>?;
    final bodyContent = bodyMap?['content'] as String? ?? '';
    final bodyTypeStr = bodyMap?['contentType'] as String? ?? 'text';

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
      parentFolderId: json['parentFolderId'] as String?,
      meetingInvite: _parseMeetingInvite(
        json['@odata.type'] as String?,
        json['meetingMessageType'] as String?,
        json,
      ),
    );
  }

  static List<EmailAttachment> _parseAttachments(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .cast<Map<String, dynamic>>()
        .where((a) => a['isInline'] != true)
        .map((a) => EmailAttachment(
              id: a['id'] as String? ?? '',
              name: a['name'] as String? ?? 'Attachment',
              contentType: a['contentType'] as String? ?? 'application/octet-stream',
              size: a['size'] as int? ?? 0,
            ))
        .toList();
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
    // Exclude acceptance/tentative/decline notifications (others responding to us).
    final type = switch (meetingMessageType) {
      'meetingRequest' => MeetingEmailType.invitation,
      'meetingCancelled' => MeetingEmailType.cancellation,
      'meetingDeclined' => MeetingEmailType.declineNotification,
      _ => null,
    };
    if (type == null) return null;

    // Parse startDateTime (DateTimeTimeZone: {dateTime, timeZone}).
    // getEmail() sends Prefer: outlook.timezone="UTC" so Graph returns the
    // dateTime string already in UTC, but without a Z suffix — append it so
    // DateTime.parse treats it as UTC rather than local time.
    DateTime? meetingStart;
    final startMap = json['startDateTime'] as Map<String, dynamic>?;
    final dtStr = startMap?['dateTime'] as String?;
    if (dtStr != null) {
      try {
        final utcStr = dtStr.endsWith('Z') ? dtStr : '${dtStr}Z';
        meetingStart = DateTime.parse(utcStr);
      } catch (_) {}
    }

    DateTime? meetingEnd;
    final endMap = json['endDateTime'] as Map<String, dynamic>?;
    final endStr = endMap?['dateTime'] as String?;
    if (endStr != null) {
      try {
        final utcStr = endStr.endsWith('Z') ? endStr : '${endStr}Z';
        meetingEnd = DateTime.parse(utcStr);
      } catch (_) {}
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
    );
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
      receivedDateTime: entity.receivedDateTime,
      sentDateTime: entity.sentDateTime,
      importance: entity.importance,
      conversationId: entity.conversationId,
      hasAttachments: entity.hasAttachments,
      attachments: entity.attachments,
      inlineAttachments: entity.inlineAttachments,
      parentFolderId: entity.parentFolderId,
      meetingInvite: entity.meetingInvite,
    );
  }
}
