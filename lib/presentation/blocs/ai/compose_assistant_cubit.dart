import 'dart:async';

import '../../../core/error/failures.dart';
import '../../../domain/entities/ai/compose_draft_snapshot.dart';
import '../../../domain/usecases/ai/run_compose_assistant.dart';
import 'agent_chat_cubit.dart';

/// Drives the compose window's AI side pane.
///
/// Each [send] reads the message as it stands right now — the editor is a
/// webview, so that is asynchronous — and runs one [RunComposeAssistant] turn
/// over it. Transcript and memory come from [AgentChatCubit]; a proposal
/// arrives as a `propose_draft` tool card, which the pane renders with Apply.
class ComposeAssistantCubit extends AgentChatCubit {
  ComposeAssistantCubit({
    required this._runAssistant,
    required this._snapshot,
  });

  final RunComposeAssistant _runAssistant;

  /// Null when the compose window cannot tell where the user's message ends
  /// and the quoted one begins — the turn is refused rather than handing the
  /// model somebody else's mail as the draft.
  final Future<ComposeDraftSnapshot?> Function() _snapshot;

  /// What a refused turn says. Shown as-is, so it must stay safe to display.
  static const String unreadableDraftMessage =
      "Couldn't tell where your message ends and the quoted message begins, "
      'so the AI was not asked. Put back the separator line above the '
      'quoted message, or delete the quote.';

  bool _preparing = false;

  Future<void> send(String instruction) async {
    if (instruction.trim().isEmpty || isBusy || _preparing) return;
    _preparing = true;
    final ComposeDraftSnapshot? snapshot;
    try {
      snapshot = await _snapshot();
    } finally {
      _preparing = false;
    }
    if (isClosed) return;
    if (snapshot == null) {
      refuseTurn(
        instruction,
        const UnsupportedFailure(message: unreadableDraftMessage),
      );
      return;
    }
    startTurn(
      instruction,
      (history, text) => _runAssistant(
        history: history,
        userInstruction: text,
        snapshot: snapshot!,
      ),
    );
  }
}
