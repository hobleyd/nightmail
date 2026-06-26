import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/ai/ai_chunk.dart';
import '../../../domain/usecases/ai/compose_reply.dart';
import 'ai_compose_state.dart';

/// Drives streaming compose / smart-reply generation.
///
/// [generate] subscribes to the [ComposeReply] use case's
/// `Stream<Either<Failure, AiChunk>>`, accumulating deltas into
/// [AiComposeStreaming.text] live so the compose editor can append them, then
/// emits [AiComposeDone] (with usage) on the terminal chunk or
/// [AiComposeError] on failure.
class AiComposeCubit extends Cubit<AiComposeState> {
  AiComposeCubit({required ComposeReply composeReply})
      : _composeReply = composeReply,
        super(const AiComposeIdle());

  final ComposeReply _composeReply;

  StreamSubscription<Either<Failure, AiChunk>>? _subscription;
  final StringBuffer _buffer = StringBuffer();

  /// Begins streaming a reply for [prompt], optionally grounded in [context]
  /// (e.g. the quoted thread being replied to).
  ///
  /// Any in-flight generation is cancelled first. Deltas accumulate into the
  /// emitted [AiComposeStreaming] state; the terminal chunk produces
  /// [AiComposeDone]; errors produce [AiComposeError].
  void generate(String prompt, {String? context}) {
    _subscription?.cancel();
    _buffer.clear();
    emit(const AiComposeStreaming(text: ''));

    _subscription =
        _composeReply(instruction: prompt, originalMessage: context).listen(
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
        // If the stream closed without a terminal chunk while still streaming,
        // settle on whatever was accumulated so the UI is not left mid-stream.
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
