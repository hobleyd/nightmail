import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/ai/ai_chunk.dart';
import '../../../domain/usecases/ai/query_email_folder.dart';
import 'ai_compose_state.dart';

/// Drives streaming Q&A and summarization over a mail folder.
///
/// Mirrors [AiComposeCubit]'s interface but delegates to [QueryEmailFolder],
/// which uses a folder-assistant system prompt instead of a compose prompt.
/// Emits the same [AiComposeState] so [AiDayPanel] is shared between both.
class AiFolderCubit extends Cubit<AiComposeState> {
  AiFolderCubit({required QueryEmailFolder queryEmailFolder})
      : _queryEmailFolder = queryEmailFolder,
        super(const AiComposeIdle());

  final QueryEmailFolder _queryEmailFolder;

  StreamSubscription<Either<Failure, AiChunk>>? _subscription;
  final StringBuffer _buffer = StringBuffer();

  /// Begins streaming a response for [prompt], optionally grounded in
  /// [context] (a pre-formatted excerpt of folder emails).
  void generate(String prompt, {String? context}) {
    _subscription?.cancel();
    _buffer.clear();
    emit(const AiComposeStreaming(text: ''));

    _subscription = _queryEmailFolder(
      instruction: prompt,
      emailsContext: context,
    ).listen(
      (result) => result.fold(
        (failure) {
          _subscription?.cancel();
          _subscription = null;
          if (!isClosed) emit(AiComposeError(failure: failure));
        },
        (chunk) {
          _buffer.write(chunk.delta);
          if (isClosed) return;
          if (chunk.done) {
            _subscription?.cancel();
            _subscription = null;
            emit(AiComposeDone(
              text: _buffer.toString(),
              finishReason: chunk.finishReason,
              promptTokens: chunk.promptTokens,
              completionTokens: chunk.completionTokens,
            ));
          } else {
            emit(AiComposeStreaming(text: _buffer.toString()));
          }
        },
      ),
      onError: (Object error) {
        _subscription?.cancel();
        _subscription = null;
        if (!isClosed) {
          emit(AiComposeError(
            failure: ProviderUnreachable(message: error.toString()),
          ));
        }
      },
      onDone: () {
        _subscription = null;
        if (!isClosed && state is AiComposeStreaming) {
          emit(AiComposeDone(text: _buffer.toString()));
        }
      },
    );
  }

  /// Cancels any in-flight generation and returns to the idle state.
  void cancel() {
    _subscription?.cancel();
    _subscription = null;
    if (!isClosed) emit(const AiComposeIdle());
  }

  @override
  Future<void> close() {
    _subscription?.cancel();
    return super.close();
  }
}
