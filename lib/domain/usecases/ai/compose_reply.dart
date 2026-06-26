import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../entities/ai/ai_capability.dart';
import '../../entities/ai/ai_chunk.dart';
import '../../entities/ai/ai_message.dart';
import '../../entities/ai/ai_provider.dart';
import '../../entities/ai/ai_request.dart';
import '../../repositories/ai/ai_catalog_repository.dart';
import '../../repositories/ai/ai_inference_repository.dart';
import '../../repositories/ai/ai_settings_repository.dart';

/// Streams an AI-drafted reply token-by-token into the compose editor.
///
/// First slice of the AI subsystem. Resolves the per-capability routing for
/// [AiCapability.compose] from [AiSettingsRepository], builds a streaming
/// [AiRequest] with a compose system prompt, and forwards the
/// `Stream<Either<Failure, AiChunk>>` produced by [AiInferenceRepository.stream].
///
/// Configuration problems surface as a single terminal `Left` rather than
/// throwing. This use case only resolves *which* provider+model handles compose
/// ([NoProviderConfigured] when none); all authentication is delegated to the
/// inference repository / wire adapter — the single source of truth for auth.
/// That keeps local/BYO providers (e.g. Ollama) usable with no API key, while a
/// catalog provider that genuinely needs one still yields [MissingApiKey] from
/// the inference layer.
///
/// ## Privacy "cloud bodies" guard (safe by default)
///
/// The quoted original email body is potentially sensitive, so it is never sent
/// to a third-party (cloud) LLM unless the user has explicitly opted in. The
/// guard reads [AiSettingsRepository.getAllowCloudForBodies] (default `false` =
/// safe) and resolves the routed provider's [AiProviderKind] via
/// [AiCatalogRepository.getProvider]. When the provider is [AiProviderKind.cloud]
/// and the opt-in flag is `false`, [originalMessage] is omitted from the prompt
/// (the model still receives the instruction, just without the quoted body). For
/// local / self-hosted providers, or when the user has enabled the flag, the body
/// is included as context. The guard fails *safe*: if the provider cannot be
/// resolved it is treated as cloud and the body is withheld.
///
/// Returns a `Stream` (not a `Future<Either<…>>`) so it does not fit the
/// `UseCase` contract — like [SearchContacts] it is a plain class with a `call`
/// method.
class ComposeReply {
  const ComposeReply({
    required this.settingsRepository,
    required this.inferenceRepository,
    required this.catalogRepository,
  });

  final AiSettingsRepository settingsRepository;
  final AiInferenceRepository inferenceRepository;
  final AiCatalogRepository catalogRepository;

  /// System prompt steering the model toward concise, ready-to-send email prose.
  static const String _systemPrompt =
      'You are an email writing assistant embedded in a desktop mail client. '
      'Draft a clear, polished email reply that fulfils the user\'s instruction. '
      'Write only the body of the message — no subject line, no preamble such as '
      '"Sure, here is", and no surrounding quotes or code fences. Match a natural, '
      'professional tone unless the instruction asks otherwise. Keep it concise '
      'and ready to send as-is.';

  /// Generates a reply for [instruction], streaming deltas as they arrive.
  ///
  /// [originalMessage] is the quoted message or thread context being replied to,
  /// when available; it is supplied to the model as additional context but is
  /// never echoed back verbatim.
  Stream<Either<Failure, AiChunk>> call({
    required String instruction,
    String? originalMessage,
  }) async* {
    // Resolve which provider + model handles compose.
    final routingResult =
        await settingsRepository.getRouting(AiCapability.compose);

    final AiRouting? routing = routingResult.fold(
      (_) => null,
      (value) => value,
    );

    if (routingResult.isLeft()) {
      yield Left(routingResult.getLeft().toNullable()!);
      return;
    }

    if (routing == null) {
      yield const Left(
        NoProviderConfigured(
          message: 'No AI provider is configured for composing replies.',
        ),
      );
      return;
    }

    // Privacy guard: decide whether the quoted email body may leave the device.
    // Resolve the routed provider's kind (fail-safe to null → treated as cloud).
    final provider = (await catalogRepository.getProvider(routing.providerId))
        .fold((_) => null, (value) => value);
    // Safe default: the opt-in flag is false unless the user enabled it.
    final allowCloud = (await settingsRepository.getAllowCloudForBodies())
        .getOrElse((_) => false);
    // Include the body for local/self-hosted providers, or when the user has
    // opted in; otherwise withhold it from cloud (third-party) providers.
    // Fail safe: an unresolved provider (null) is treated as cloud so the body
    // is withheld at the safe default rather than leaking to an unknown route.
    final isCloud = provider == null || provider.kind == AiProviderKind.cloud;
    final includeBody = !isCloud || allowCloud;

    // Auth (and the requiresApiKey/local decision) is the inference layer's job;
    // we do not gate on a key here, so local providers like Ollama work keyless.
    final request = AiRequest(
      providerId: routing.providerId,
      modelId: routing.modelId,
      stream: true,
      messages: [
        const AiMessage(role: AiRole.system, content: _systemPrompt),
        AiMessage(
          role: AiRole.user,
          content: _buildUserPrompt(
            instruction: instruction,
            originalMessage: includeBody ? originalMessage : null,
          ),
        ),
      ],
    );

    yield* inferenceRepository.stream(request);
  }

  /// Combines the user's [instruction] with any [originalMessage] context into a
  /// single user-turn prompt.
  String _buildUserPrompt({
    required String instruction,
    String? originalMessage,
  }) {
    final context = originalMessage?.trim();
    if (context == null || context.isEmpty) {
      return instruction.trim();
    }
    return 'Instruction:\n${instruction.trim()}\n\n'
        'Message being replied to:\n$context';
  }
}
