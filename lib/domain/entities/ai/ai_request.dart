import 'package:equatable/equatable.dart';

import 'ai_message.dart';

/// The wire shape an adapter should use for a request.
///
/// - [completions]: the OpenAI Chat Completions API (`/chat/completions`).
/// - [responses]: the OpenAI Responses API (`/responses`).
///
/// Resolved per-model from the provider catalog (a model's `providerOverride`
/// may declare `shape: 'responses'`); features never set this directly.
enum AiRequestShape { completions, responses }

/// A normalized inference request handed to an [AiAdapter].
///
/// Adapters map this to their provider's wire format; features never construct
/// provider-specific shapes.
class AiRequest extends Equatable {
  const AiRequest({
    required this.messages,
    required this.providerId,
    required this.modelId,
    this.temperature,
    this.maxTokens,
    this.stream = false,
    this.shape = AiRequestShape.completions,
  });

  final List<AiMessage> messages;
  final String providerId;
  final String modelId;
  final double? temperature;
  final int? maxTokens;
  final bool stream;

  /// The wire shape the adapter should use (completions vs responses).
  final AiRequestShape shape;

  AiRequest copyWith({
    List<AiMessage>? messages,
    String? providerId,
    String? modelId,
    double? temperature,
    int? maxTokens,
    bool? stream,
    AiRequestShape? shape,
  }) {
    return AiRequest(
      messages: messages ?? this.messages,
      providerId: providerId ?? this.providerId,
      modelId: modelId ?? this.modelId,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      stream: stream ?? this.stream,
      shape: shape ?? this.shape,
    );
  }

  @override
  List<Object?> get props => [
        messages,
        providerId,
        modelId,
        temperature,
        maxTokens,
        stream,
        shape,
      ];
}
