import 'package:equatable/equatable.dart';

import '../../../domain/usecases/send_email.dart';

sealed class ComposeEvent extends Equatable {
  const ComposeEvent();

  @override
  List<Object?> get props => [];
}

final class ComposeSubmitted extends ComposeEvent {
  const ComposeSubmitted({
    required this.mode,
    this.originalMessageId,
    required this.toAddresses,
    this.ccAddresses = const [],
    required this.subject,
    required this.body,
    this.excludedAttachmentIds = const [],
  });

  final ComposeMode mode;
  final String? originalMessageId;
  final List<String> toAddresses;
  final List<String> ccAddresses;
  final String subject;
  final String body;
  final List<String> excludedAttachmentIds;

  @override
  List<Object?> get props =>
      [mode, originalMessageId, toAddresses, ccAddresses, subject, body, excludedAttachmentIds];
}
