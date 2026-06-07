import '../../domain/entities/email.dart';
import '../../domain/entities/email_attachment.dart';
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
    super.parentFolderId,
  });

  factory EmailModel.fromJson(Map<String, dynamic> json) {
    final bodyMap = json['body'] as Map<String, dynamic>?;
    final bodyContent = bodyMap?['content'] as String? ?? '';
    final bodyTypeStr = bodyMap?['contentType'] as String? ?? 'text';

    return EmailModel(
      id: json['id'] as String,
      subject: json['subject'] as String? ?? '(No Subject)',
      from: EmailAddressModel.fromJson(
        json['from'] as Map<String, dynamic>? ?? {},
      ),
      toRecipients: (json['toRecipients'] as List<dynamic>? ?? [])
          .map((r) => EmailAddressModel.fromJson(r as Map<String, dynamic>))
          .toList(),
      ccRecipients: (json['ccRecipients'] as List<dynamic>? ?? [])
          .map((r) => EmailAddressModel.fromJson(r as Map<String, dynamic>))
          .toList(),
      bodyPreview: json['bodyPreview'] as String? ?? '',
      body: bodyContent,
      bodyType: bodyTypeStr == 'html' ? EmailBodyType.html : EmailBodyType.text,
      isRead: json['isRead'] as bool? ?? false,
      receivedDateTime: DateTime.parse(
        json['receivedDateTime'] as String,
      ),
      sentDateTime: json['sentDateTime'] != null
          ? DateTime.tryParse(json['sentDateTime'] as String)
          : null,
      importance: _parseImportance(json['importance'] as String?),
      conversationId: json['conversationId'] as String?,
      hasAttachments: json['hasAttachments'] as bool? ?? false,
      attachments: _parseAttachments(json['attachments']),
      parentFolderId: json['parentFolderId'] as String?,
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
      parentFolderId: entity.parentFolderId,
    );
  }
}
