import '../../../domain/usecases/ai/run_folder_agent.dart';
import 'agent_chat_cubit.dart';

/// Drives the multi-turn, tool-calling folder agent chat.
///
/// Each [send] streams one agent turn via [RunFolderAgent], which may call
/// read-only tools to read/search the user's mail before answering. The
/// transcript and conversation memory live in [AgentChatCubit], shared with
/// the commitments agent; this class only knows how to run a folder turn —
/// the panel's current folder (the tool default) and the pre-formatted folder
/// excerpt used when the routed model lacks tool calling.
class AiFolderCubit extends AgentChatCubit {
  AiFolderCubit({required this._runFolderAgent});

  final RunFolderAgent _runFolderAgent;

  void send(
    String userInstruction, {
    String? currentFolderId,
    String? fallbackEmailsContext,
  }) {
    startTurn(
      userInstruction,
      (history, instruction) => _runFolderAgent.call(
        history: history,
        userInstruction: instruction,
        currentFolderId: currentFolderId,
        fallbackEmailsContext: fallbackEmailsContext,
      ),
    );
  }
}
