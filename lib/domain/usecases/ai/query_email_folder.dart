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

/// Streams an AI response to a question or summarization request over a folder
/// of emails, token-by-token.
///
/// Routes through [AiCapability.compose] (the configured slice) and applies the
/// same privacy guard as [ComposeReply]: email content is withheld from cloud
/// providers unless the user has explicitly opted in via
/// [AiSettingsRepository.getAllowCloudForBodies].
class QueryEmailFolder {
  const QueryEmailFolder({
    required this.settingsRepository,
    required this.inferenceRepository,
    required this.catalogRepository,
  });

  final AiSettingsRepository settingsRepository;
  final AiInferenceRepository inferenceRepository;
  final AiCatalogRepository catalogRepository;

  static const String _systemPrompt =
      'You are an email assistant embedded in a desktop mail client. '
      'Help the user understand, manage, and triage their emails. '
      'When given a list of emails from a folder, use that context to answer '
      'questions, provide summaries, identify urgent items, and help the user '
      'prioritise their inbox. Be concise and specific.';

  /// Generates a response for [instruction], optionally grounded in
  /// [emailsContext] (a pre-formatted excerpt of folder emails).
  ///
  /// Email content is subject to the cloud-bodies privacy guard: it is omitted
  /// when routed to a cloud provider and the user has not opted in.
  Stream<Either<Failure, AiChunk>> call({
    required String instruction,
    String? emailsContext,
  }) async* {
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
          message: 'No AI provider is configured.',
        ),
      );
      return;
    }

    final provider = (await catalogRepository.getProvider(routing.providerId))
        .fold((_) => null, (value) => value);
    final allowCloud = (await settingsRepository.getAllowCloudForBodies())
        .getOrElse((_) => false);
    final isCloud = provider == null || provider.kind == AiProviderKind.cloud;
    final includeContext = !isCloud || allowCloud;

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
            emailsContext: includeContext ? emailsContext : null,
          ),
        ),
      ],
    );

    yield* inferenceRepository.stream(request);
  }

  String _buildUserPrompt({
    required String instruction,
    String? emailsContext,
  }) {
    final ctx = emailsContext?.trim();
    if (ctx == null || ctx.isEmpty) return instruction.trim();
    return 'Emails in folder:\n$ctx\n\nInstruction:\n${instruction.trim()}';
  }
}
