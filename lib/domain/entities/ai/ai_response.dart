import 'package:equatable/equatable.dart';

/// The full result of a single-shot AI inference request.
class AiResponse extends Equatable {
  const AiResponse({
    required this.text,
    this.promptTokens,
    this.completionTokens,
    this.finishReason,
  });

  final String text;
  final int? promptTokens;
  final int? completionTokens;
  final String? finishReason;

  @override
  List<Object?> get props => [
        text,
        promptTokens,
        completionTokens,
        finishReason,
      ];
}
