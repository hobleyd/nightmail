import 'package:equatable/equatable.dart';
import 'email_address.dart';

enum EmailBodyType { text, html }

enum EmailImportance { low, normal, high }

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
    this.parentFolderId,
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
  final String? parentFolderId;

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
      parentFolderId: parentFolderId,
    );
  }

  @override
  List<Object?> get props => [id];
}
