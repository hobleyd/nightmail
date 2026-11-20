import 'dart:convert';

import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';
import 'agent_tool.dart';

/// The compose assistant's one tool: hands the user a complete new version of
/// the message.
///
/// It changes nothing itself. The proposal reaches the compose window as the
/// tool card the call produces, and the compose form puts it into the message
/// from there (with Undo on the card) — so the edit is a presentation-layer
/// action, and the result only tells the model what the user will see.
class ProposeDraftTool implements AgentTool {
  const ProposeDraftTool();

  static const String toolName = 'propose_draft';

  @override
  String get name => toolName;

  @override
  String get description =>
      'Offer the user a complete new version of the message they are '
      'writing. Pass the whole message — every paragraph, not only the part '
      'that changed — as plain text with paragraphs separated by a blank '
      'line. Never include the quoted earlier message. It replaces what the '
      'user has written straight away; they can undo it.';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': 'The full proposed message body, plain text.',
          },
        },
        'required': ['text'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final text = args['text'];
    if (text is! String || text.trim().isEmpty) {
      return Right(jsonEncode({
        'error': 'propose_draft needs the full message as "text".',
      }));
    }
    return Right(jsonEncode({
      'status': 'put_in_message',
      'note': "The proposal has replaced what the user had written, and they "
          'can undo it. Say briefly what you wrote or changed; do not repeat '
          'the message itself.',
    }));
  }
}
