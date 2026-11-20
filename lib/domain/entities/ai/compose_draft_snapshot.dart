import 'package:equatable/equatable.dart';

/// What the compose assistant can see of the message being written, read
/// fresh from the compose window at the start of every turn so the model
/// always works on the user's latest edits.
///
/// [draft] is only the part the user is writing: the text above the quoted
/// reply or forwarded message, with the signature taken out. The quoted
/// message travels separately as [originalMessage], as background the model
/// may read but must never review or rewrite.
class ComposeDraftSnapshot extends Equatable {
  const ComposeDraftSnapshot({
    required this.draft,
    this.subject = '',
    this.to = const [],
    this.cc = const [],
    this.isReply = false,
    this.isForward = false,
    this.signatureSeparated = false,
    this.originalMessage,
  });

  /// The composition as plain text; empty when nothing has been written yet.
  final String draft;

  final String subject;

  /// Recipients as display strings (`Name <address>` or a bare address).
  final List<String> to;
  final List<String> cc;

  final bool isReply;
  final bool isForward;

  /// True when the signature was found and taken out of [draft]; it is put
  /// back around an applied proposal. False when there is none, or it was
  /// edited past recognition — then any sign-off is part of [draft].
  final bool signatureSeparated;

  /// The message being replied to or forwarded, as plain text, when there is
  /// one. Subject to the cloud-bodies privacy guard in the use case.
  final String? originalMessage;

  @override
  List<Object?> get props => [
        draft,
        subject,
        to,
        cc,
        isReply,
        isForward,
        signatureSeparated,
        originalMessage,
      ];
}
