import 'dart:convert';

import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';
import 'agent_tool.dart';

/// The compose assistant's one tool: hands the user a complete revised draft.
///
/// It changes nothing. The proposal reaches the compose window as the tool
/// card the call produces, and the user decides there whether to apply it —
/// so the edit itself is a presentation-layer action, and the model is told
/// as much in the result so it does not claim the draft was changed.
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
      'line. Never include the quoted earlier message. The '
      'user sees it with an Apply button; nothing changes until they press '
      'it.';

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
      'status': 'shown_to_user',
      'note': 'The proposal is shown to the user with an Apply button. It '
          'has not been applied; do not say the draft was changed.',
    }));
  }
}
