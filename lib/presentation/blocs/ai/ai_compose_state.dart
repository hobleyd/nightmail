import 'package:equatable/equatable.dart';

import '../../../core/error/failures.dart';

/// State for [AiComposeCubit], driving the streaming compose/smart-reply flow.
sealed class AiComposeState extends Equatable {
  const AiComposeState();

  @override
  List<Object?> get props => [];
}

/// No generation in progress; nothing has been produced yet.
final class AiComposeIdle extends AiComposeState {
  const AiComposeIdle();
}

/// A generation is in flight; [text] is the accumulated delta so far.
final class AiComposeStreaming extends AiComposeState {
  const AiComposeStreaming({required this.text});

  /// The accumulated text streamed from the provider up to this point.
  final String text;

  @override
  List<Object?> get props => [text];
}

/// The generation completed successfully.
final class AiComposeDone extends AiComposeState {
  const AiComposeDone({
    required this.text,
    this.finishReason,
    this.promptTokens,
    this.completionTokens,
  });

  /// The full generated text.
  final String text;

  /// Why the provider stopped generating (e.g. `stop`, `length`).
  final String? finishReason;

  /// Tokens consumed by the prompt, if reported by the provider.
  final int? promptTokens;

  /// Tokens produced in the completion, if reported by the provider.
  final int? completionTokens;

  @override
  List<Object?> get props => [
        text,
        finishReason,
        promptTokens,
        completionTokens,
      ];
}

/// The generation failed.
final class AiComposeError extends AiComposeState {
  const AiComposeError({required this.failure});

  final Failure failure;

  @override
  List<Object?> get props => [failure];
}
