import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/ai/ai_chunk.dart';
import '../../../domain/entities/ai/ai_message.dart';
import '../../../domain/usecases/ai/agent/agent_loop.dart';
import 'ai_folder_chat_state.dart';

/// Runs one agent turn given the conversation so far and the new instruction.
typedef AgentTurnRunner = Stream<Either<Failure, AiChunk>> Function(
  List<AiMessage> history,
  String instruction,
);

/// The transcript half of a tool-calling agent chat, shared by the folder
/// agent and the commitments agent.
///
/// Owns the running conversation [_history] (user + assistant text turns,
/// fed back to the agent each turn so follow-ups have memory) and the
/// displayable transcript [_display], which interleaves text bubbles with
/// inline [AiToolItem] cards and so is not 1:1 with the history. Each display
/// item is tagged with the user-turn index it belongs to ([_turnOf]); when
/// [_trimHistory] drops the oldest text turns, their display items go too.
/// Tool items are display-only and never re-sent.
///
/// Subclasses supply the turn: [startTurn] takes the instruction and a
/// runner that streams the agent given the retained history. The agent owns
/// the system prompt, so it is deliberately absent from [_history].
abstract class AgentChatCubit extends Cubit<AiFolderChatState> {
  AgentChatCubit() : super(const AiFolderChatState());

  final List<AiMessage> _history = [];
  final List<int> _historyTurns = [];
  final List<AiChatItem> _display = [];
  final Map<String, int> _turnOf = {};

  StreamSubscription<Either<Failure, AiChunk>>? _subscription;

  /// The CURRENT text segment's streamed text; cleared whenever a tool card
  /// closes the running segment, so narration between tool calls becomes
  /// separate bubbles.
  final StringBuffer _buffer = StringBuffer();

  /// ALL assistant text across the turn, for the single history entry.
  final StringBuffer _turnText = StringBuffer();

  String? _streamingId;
  int _seq = 0;
  int _turn = 0;
  int _currentTurn = 0;

  /// Max conversation turns retained (combined user + assistant text turns).
  static const int maxHistory = 12;

  /// Whether a turn is streaming right now.
  bool get isBusy => _subscription != null;

  /// Hook for subclasses: called once a turn has settled, whether it
  /// finished, was cancelled or failed. The commitments agent reloads the
  /// ledger here, since its tools change it.
  @protected
  void onTurnEnded() {}

  /// Starts a turn for [userInstruction]; ignored while one is in flight or
  /// when the instruction is blank.
  @protected
  void startTurn(String userInstruction, AgentTurnRunner run) {
    final instruction = userInstruction.trim();
    if (instruction.isEmpty || _subscription != null) return;

    _buffer.clear();
    _turnText.clear();
    _streamingId = null;

    // The history handed to the agent EXCLUDES the new user turn — the agent
    // appends it itself.
    final history = List<AiMessage>.unmodifiable(_history);

    final thisTurn = _turn++;
    _currentTurn = thisTurn;

    // Record the user turn (history + display). The assistant bubble is NOT
    // created up front — it is added lazily on the first text delta, so tool
    // cards render above the eventual answer.
    _history.add(AiMessage(role: AiRole.user, content: instruction));
    _historyTurns.add(thisTurn);

    final userId = 'u${_seq++}';
    _display.add(AiTextMessage(id: userId, isUser: true, text: instruction));
    _turnOf[userId] = thisTurn;

    _emit(isStreaming: true, clearFailure: true);

    _subscription = run(history, instruction).listen(
      (result) => result.fold(_onFailure, _onChunk),
      onError: (Object error) =>
          _onFailure(ProviderUnreachable(message: error.toString())),
      onDone: _onStreamDone,
    );
  }

  /// Clears the conversation and returns to the empty state.
  void reset() {
    _subscription?.cancel();
    _subscription = null;
    _buffer.clear();
    _turnText.clear();
    _history.clear();
    _historyTurns.clear();
    _display.clear();
    _turnOf.clear();
    _streamingId = null;
    _turn = 0;
    _currentTurn = 0;
    if (!isClosed) emit(const AiFolderChatState());
  }

  /// Cancels an in-flight turn, keeping whatever text and tool cards streamed
  /// so far.
  void cancel() {
    if (_subscription == null) return;
    _finalizeTurn();
  }

  @override
  Future<void> close() {
    _subscription?.cancel();
    return super.close();
  }

  // --- Stream handlers -------------------------------------------------------

  void _onChunk(AiChunk chunk) {
    if (isClosed) return;

    // A tool call started — append a running tool card to the transcript.
    if (chunk.finishReason == AgentLoop.toolActivityFinishReason) {
      final calls = chunk.toolCalls;
      if (calls != null && calls.isNotEmpty) {
        for (final call in calls) {
          final item = AiToolItem(
            id: 't${_seq++}',
            callId: call.id,
            name: call.name,
            args: call.arguments,
            status: AiToolStatus.running,
          );
          _display.add(item);
          _turnOf[item.id] = _currentTurn;
        }

        // Close the current text segment so any answer text that streams
        // AFTER this tool starts a fresh bubble BELOW the card.
        if (_streamingId != null) {
          _streamingId = null;
          _buffer.clear();
          if (_turnText.isNotEmpty) _turnText.write('\n\n');
        }
        _emit();
      }
      return;
    }

    // A tool call finished — update its running card to complete/error.
    if (chunk.finishReason == AgentLoop.toolResultFinishReason) {
      final result = chunk.toolResult;
      if (result != null) {
        // Scope the match to the current turn so a callId reused from an
        // older turn can't update the wrong card.
        final i = _display.indexWhere(
          (m) =>
              m is AiToolItem &&
              m.callId == result.callId &&
              _turnOf[m.id] == _currentTurn,
        );
        if (i != -1) {
          final existing = _display[i] as AiToolItem;
          _display[i] = existing.copyWith(
            status:
                result.isError ? AiToolStatus.error : AiToolStatus.complete,
            output: result.output,
          );
          _emit();
        }
      }
      return;
    }

    // Real answer text. Create the in-flight assistant bubble lazily on the
    // first non-empty content so it sits below any tool cards.
    _buffer.write(chunk.delta);
    _turnText.write(chunk.delta);
    if (_streamingId == null && _buffer.isNotEmpty) {
      _streamingId = 'a${_seq++}';
      _display.add(AiTextMessage(id: _streamingId!, isUser: false, text: ''));
      _turnOf[_streamingId!] = _currentTurn;
    }
    _setStreamingText(_buffer.toString());

    if (chunk.done) {
      _finalizeTurn();
    } else {
      _emit();
    }
  }

  void _onFailure(Failure failure) {
    _subscription?.cancel();
    _subscription = null;

    // Drop the in-flight assistant bubble only if it never produced text; the
    // panel renders the failure separately. Tool cards persist.
    final id = _streamingId;
    if (id != null) {
      final i = _display.indexWhere((m) => m.id == id);
      if (i != -1) {
        final m = _display[i];
        if (m is AiTextMessage && m.text.isEmpty) {
          _display.removeAt(i);
          _turnOf.remove(id);
        }
      }
    }
    _streamingId = null;
    _buffer.clear();
    _settleRunningToolCards();
    _trimHistory();

    if (!isClosed) _emit(isStreaming: false, failure: failure);
    onTurnEnded();
  }

  void _onStreamDone() {
    // The stream closed without a terminal `done` chunk (e.g. a fallback
    // path). Finalize whatever streamed so far.
    if (_subscription != null) _finalizeTurn();
    _subscription = null;
  }

  /// Settles the in-flight turn: persists the assistant text into [_history],
  /// trims to the cap, and emits the idle (non-streaming) state.
  void _finalizeTurn() {
    _subscription?.cancel();
    _subscription = null;

    final turnText = _turnText.toString().trim();
    if (turnText.isNotEmpty) {
      _history.add(AiMessage(role: AiRole.assistant, content: turnText));
      _historyTurns.add(_currentTurn);
    }
    if (_buffer.isEmpty) {
      // Drop a trailing empty in-flight bubble (e.g. cancelled before this
      // segment produced any text).
      final id = _streamingId;
      if (id != null) {
        _display.removeWhere((m) => m.id == id);
        _turnOf.remove(id);
      }
    }

    _streamingId = null;
    _buffer.clear();
    _turnText.clear();
    _settleRunningToolCards();
    _trimHistory();

    if (!isClosed) _emit(isStreaming: false);
    onTurnEnded();
  }

  // --- Internals -------------------------------------------------------------

  /// Marks any still-running tool card of the current turn as an error, so a
  /// turn that ended without its result stops spinning.
  void _settleRunningToolCards() {
    for (var i = 0; i < _display.length; i++) {
      final m = _display[i];
      if (m is AiToolItem &&
          m.status == AiToolStatus.running &&
          _turnOf[m.id] == _currentTurn) {
        _display[i] = m.copyWith(status: AiToolStatus.error);
      }
    }
  }

  void _setStreamingText(String text) {
    final id = _streamingId;
    if (id == null) return;
    final i = _display.indexWhere((m) => m.id == id);
    if (i != -1) {
      final m = _display[i];
      if (m is AiTextMessage) _display[i] = m.copyWith(text: text);
    }
  }

  /// Trims [_history] to the most recent [maxHistory] text turns, then drops
  /// display items belonging to turns that are no longer retained.
  void _trimHistory() {
    final overflow = _history.length - maxHistory;
    if (overflow <= 0) return;
    _history.removeRange(0, overflow);
    _historyTurns.removeRange(0, overflow);

    final oldestTurn =
        _historyTurns.isEmpty ? _currentTurn : _historyTurns.first;
    _display.removeWhere((m) {
      final t = _turnOf[m.id];
      if (t != null && t < oldestTurn) {
        _turnOf.remove(m.id);
        return true;
      }
      return false;
    });
  }

  void _emit({
    bool? isStreaming,
    Failure? failure,
    bool clearFailure = false,
  }) {
    emit(
      state.copyWith(
        messages: List<AiChatItem>.unmodifiable(_display),
        isStreaming: isStreaming,
        failure: failure,
        clearFailure: clearFailure,
      ),
    );
  }
}
