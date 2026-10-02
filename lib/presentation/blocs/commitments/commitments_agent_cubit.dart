import 'dart:async';

import '../../../core/error/failures.dart';
import '../../../domain/usecases/commitments/agent/commitment_agent_tools.dart';
import '../../../domain/usecases/commitments/run_commitments_agent.dart';
import '../ai/agent_chat_cubit.dart';

/// Drives the natural-language control chat in the Commitments pane.
///
/// Each [send] runs one [RunCommitmentsAgent] turn over a snapshot the
/// Commitments cubit supplies (ledger, calendar ahead, task due dates, the
/// clock) and, since the agent's tools change the ledger, asks it to reload
/// once the turn settles. Transcript and memory come from [AgentChatCubit].
class CommitmentsAgentCubit extends AgentChatCubit {
  CommitmentsAgentCubit({
    required this._runAgent,
    required this._snapshot,
    required this._onChanged,
  });

  final RunCommitmentsAgent _runAgent;
  final CommitmentsAgentSnapshot? Function() _snapshot;
  final Future<void> Function() _onChanged;

  /// Runs one turn for [instruction]. Without a loaded account there is no
  /// ledger to act on, which is reported as a failure rather than a turn.
  void send(String instruction) {
    final snapshot = _snapshot();
    if (snapshot == null) {
      emit(state.copyWith(
        failure: const NoProviderConfigured(
          message: 'Sign in to an account to manage commitments.',
        ),
      ));
      return;
    }
    startTurn(
      instruction,
      (history, text) => _runAgent.call(
        history: history,
        userInstruction: text,
        snapshot: snapshot,
      ),
    );
  }

  @override
  void onTurnEnded() => unawaited(_onChanged());
}
