import 'package:equatable/equatable.dart';

/// A single streaming delta from an AI inference stream.
///
/// Deltas are appended into the compose editor live; the terminal chunk
/// ([done] == true) carries [finishReason] and usage counts.
class AiChunk extends Equatable {
  const AiChunk({
    required this.delta,
    this.done = false,
    this.finishReason,
    this.promptTokens,
    this.completionTokens,
  });

  final String delta;
  final bool done;
  final String? finishReason;
  final int? promptTokens;
  final int? completionTokens;

  @override
  List<Object?> get props => [
        delta,
        done,
        finishReason,
        promptTokens,
        completionTokens,
      ];
}
