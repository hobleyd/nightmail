import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../entities/ai/ai_capability.dart';
import '../../entities/ai/ai_chunk.dart';
import '../../entities/ai/ai_message.dart';
import '../../entities/ai/ai_provider.dart';
import '../../entities/ai/ai_request.dart';
import '../../entities/ai/ai_tool_call.dart';
import '../../entities/ai/compose_draft_snapshot.dart';
import '../../repositories/ai/ai_catalog_repository.dart';
import '../../repositories/ai/ai_inference_repository.dart';
import '../../repositories/ai/ai_settings_repository.dart';
import 'agent/agent_loop.dart';
import 'agent/compose_agent_tools.dart';

/// Runs one turn of the compose window's AI side pane: a chat about the
/// message being written that can draft it, review it, and propose revisions.
///
/// The third agent on [AgentLoop], beside the folder and commitments agents.
/// Routing reuses [AiCapability.compose]. Its only tool is
/// [ProposeDraftTool], which changes nothing itself — the compose window
/// puts each proposal into the message, with Undo on its card.
///
/// ## The draft lives in the system prompt
///
/// The user keeps editing between turns, so the [ComposeDraftSnapshot] is
/// read fresh each turn and rebuilt into the system prompt rather than
/// appended to [history]: history holds only what was said, and does not fill
/// with stale copies of the draft.
///
/// ## Privacy guard
///
/// The same cloud-bodies rule as the folder agent: the quoted message being
/// replied to or forwarded is somebody else's mail, so it is withheld from a
/// cloud provider unless the user opted in. An unresolved provider counts as
/// cloud. The draft itself is the user's own writing and is always sent — it
/// is the thing they asked for help with.
///
/// When the routed model cannot call tools (a cloud model the catalog marks
/// so), the turn runs as plain chat with the same context and the model is
/// told to give revised text in its answer instead.
class RunComposeAssistant {
  const RunComposeAssistant({
    required this.settingsRepository,
    required this.inferenceRepository,
    required this.catalogRepository,
  });

  final AiSettingsRepository settingsRepository;
  final AiInferenceRepository inferenceRepository;
  final AiCatalogRepository catalogRepository;

  /// A proposal then a sentence about it is two rounds; the third is slack.
  static const int maxRounds = 3;
  static const int maxToolCallsPerRound = 2;

  /// The quoted message is background, and a long thread would crowd out the
  /// conversation; the head of it is what a reply answers.
  static const int maxOriginalChars = 12000;

  static const String _rules =
      'You are a writing assistant built into the compose window of a desktop '
      'mail client. You help the user with the message they are writing: '
      'drafting it from scratch, reviewing it, answering questions about it, '
      'and revising it.\n'
      '\n'
      'Only the current draft below is yours to review or change. The earlier '
      'message being replied to or forwarded, when it is shown, is background '
      'for understanding what the user is answering — never review it, '
      'comment on its writing, or include it in a proposal.\n'
      '\n'
      'When the user asks for a review or feedback, answer in a few specific, '
      'concise points (tone, clarity, missing information, mistakes) and '
      'quote the words you mean. Do not rewrite the draft unless asked.\n';

  static const String _toolRules =
      'When the user asks you to write, rewrite, shorten, fix or otherwise '
      'change the draft, call propose_draft with the complete new message — '
      'never write the message itself in your reply; it goes straight into '
      'the compose window — then say in one or two sentences what you wrote '
      'or changed. Write the proposal '
      'in plain text, paragraphs separated by a blank line: no Markdown, no '
      'subject line, no surrounding quotes. Keep anything the user did not '
      'ask you to change.\n';

  static const String _fallbackRules =
      'You cannot change the draft yourself. When the user asks for a new '
      'version, give the complete message in plain text, with no Markdown, '
      'so they can copy it in.\n';

  static const String _signatureKept =
      'The signature is not part of the draft below and is kept '
      'automatically: never add one.\n';

  static const String _signatureInDraft =
      'If the draft ends with a sign-off or signature, keep it unchanged at '
      'the end of any new version.\n';

  Stream<Either<Failure, AiChunk>> call({
    required List<AiMessage> history,
    required String userInstruction,
    required ComposeDraftSnapshot snapshot,
  }) async* {
    final routingResult =
        await settingsRepository.getRouting(AiCapability.compose);
    if (routingResult.isLeft()) {
      yield Left(routingResult.getLeft().toNullable()!);
      return;
    }
    final routing = routingResult.getRight().toNullable();
    if (routing == null) {
      yield const Left(
        NoProviderConfigured(message: 'No AI provider is configured.'),
      );
      return;
    }

    final provider = (await catalogRepository.getProvider(routing.providerId))
        .fold((_) => null, (value) => value);
    final allowCloud = (await settingsRepository.getAllowCloudForBodies())
        .getOrElse((_) => false);
    final isCloud = provider == null || provider.kind == AiProviderKind.cloud;
    final includeOriginal = !isCloud || allowCloud;

    // The same tool-capability rule as RunFolderAgent: the catalog flag is
    // only meaningful for cloud providers; a local/BYO model is tried.
    final model = (await catalogRepository.getModel(
      providerId: routing.providerId,
      modelId: routing.modelId,
    ))
        .fold((_) => null, (value) => value);
    final toolCapable = isCloud ? (model?.toolCall ?? false) : true;

    final systemPrompt = buildSystemPrompt(
      snapshot,
      includeOriginal: includeOriginal,
      toolCapable: toolCapable,
    );

    if (!toolCapable) {
      yield* inferenceRepository.stream(AiRequest(
        providerId: routing.providerId,
        modelId: routing.modelId,
        stream: true,
        messages: [
          AiMessage(role: AiRole.system, content: systemPrompt),
          ...history,
          AiMessage(role: AiRole.user, content: userInstruction),
        ],
      ));
      return;
    }

    yield* AgentLoop(inferenceRepository).run(
      routing: routing,
      systemPrompt: systemPrompt,
      tools: const [ProposeDraftTool()],
      history: history,
      userInstruction: userInstruction,
      maxRounds: maxRounds,
      maxToolCallsPerRound: maxToolCallsPerRound,
      activityLabel: _activityLabel,
    );
  }

  /// The rules plus this turn's view of the message. Public for tests.
  static String buildSystemPrompt(
    ComposeDraftSnapshot snapshot, {
    required bool includeOriginal,
    required bool toolCapable,
  }) {
    final b = StringBuffer(_rules)
      ..write('\n')
      ..write(toolCapable ? _toolRules : _fallbackRules)
      ..write(snapshot.signatureSeparated ? _signatureKept : _signatureInDraft)
      ..write('\n');

    final kind = snapshot.isReply
        ? 'a reply'
        : snapshot.isForward
            ? 'a forward'
            : 'a new message';
    b.writeln('The user is writing $kind.');
    if (snapshot.subject.trim().isNotEmpty) {
      b.writeln('Subject: ${snapshot.subject.trim()}');
    }
    if (snapshot.to.isNotEmpty) b.writeln('To: ${snapshot.to.join(', ')}');
    if (snapshot.cc.isNotEmpty) b.writeln('Cc: ${snapshot.cc.join(', ')}');
    b.writeln();

    final draft = snapshot.draft.trim();
    if (draft.isEmpty) {
      b.writeln('Current draft: (empty — nothing has been written yet)');
    } else {
      b
        ..writeln('Current draft (everything between the markers):')
        ..writeln('<<<DRAFT')
        ..writeln(draft)
        ..writeln('DRAFT>>>');
    }

    final original = snapshot.originalMessage?.trim();
    if (original != null && original.isNotEmpty) {
      b.writeln();
      if (includeOriginal) {
        final clipped = original.length > maxOriginalChars
            ? '${original.substring(0, maxOriginalChars)}\n[…truncated]'
            : original;
        b
          ..writeln(snapshot.isForward
              ? 'Message being forwarded (background only, not part of the '
                  'draft):'
              : 'Message being replied to (background only, not part of the '
                  'draft):')
          ..writeln('<<<ORIGINAL')
          ..writeln(clipped)
          ..writeln('ORIGINAL>>>');
      } else {
        b.writeln('The earlier message is not shown to you (the user keeps '
            'email bodies away from cloud AI providers). If you need it, ask '
            'the user what it said.');
      }
    }
    return b.toString();
  }

  String _activityLabel(AiToolCall call) => switch (call.name) {
        ProposeDraftTool.toolName => 'Writing a proposal…',
        _ => 'Using ${call.name}…',
      };
}
