import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/latest_reply.dart' show htmlToPlainText;
import '../../entities/ai/ai_capability.dart';
import '../../entities/ai/ai_chunk.dart';
import '../../entities/ai/ai_message.dart';
import '../../entities/ai/ai_provider.dart';
import '../../entities/ai/ai_request.dart';
import '../../entities/ai/ai_tool_call.dart';
import '../../entities/email.dart';
import '../../repositories/ai/ai_catalog_repository.dart';
import '../../repositories/ai/ai_inference_repository.dart';
import '../../repositories/ai/ai_settings_repository.dart';
import '../check_sender_anomaly.dart';
import '../get_email.dart';
import '../get_emails.dart';
import '../get_mail_folders.dart';
import '../get_raw_email_bytes.dart';
import '../search_emails.dart';
import 'agent/agent_loop.dart';
import 'agent/agent_tool.dart';
import 'agent/email_agent_tools.dart';

/// Runs a tool-calling agent scoped to the folder panel, streaming the
/// response token-by-token.
///
/// Replaces the single-shot [QueryEmailFolder] for tool-capable models: instead
/// of pre-stuffing folder emails into the prompt, the model is given read-only
/// tools ([ListEmailsTool], [GetEmailTool], [SearchEmailsTool],
/// [ListFoldersTool], [CheckEmailSafetyTool], and [ShowEmailsTool] to name its
/// pick) to read/search mail on demand. Multi-turn threading is
/// the caller's responsibility — it passes the accumulated [history] each turn.
///
/// ## The open email
///
/// The message open in the reading pane is named in the system prompt, which
/// is rebuilt every turn (the user moves between messages while the pane
/// stays open, so it cannot live in history). Without it, "is this email
/// malicious?" sent the model off to `list_emails`, and it answered about
/// whichever message it found. For a local provider the open message's text
/// goes in too, so a small model need not think to call `get_email` first.
///
/// Routing reuses [AiCapability.compose]. When the routed model does not
/// support tool calling (`AiModel.toolCall == false`), this falls back to the
/// pre-stuffed-context Q&A (still threaded), so the panel always works.
///
/// ## Privacy guard (§4)
///
/// The cloud-bodies guard moves to the tool boundary: the use case computes the
/// effective `includeBodies` policy once (cloud provider + no opt-in →
/// withhold) and passes it to [GetEmailTool], which then returns metadata +
/// preview only. `list_emails` / `search_emails` expose only previews, so the
/// guarantee — full bodies never leave to a cloud provider without explicit
/// opt-in — is preserved. The fallback path gates [fallbackEmailsContext] with
/// the same flag.
///
/// Returns a `Stream<Either<Failure, AiChunk>>`: text deltas pass through
/// unchanged, transient tool-activity chunks are emitted with
/// [toolActivityFinishReason], and a hard provider failure surfaces as a single
/// terminal `Left`.
class RunFolderAgent {
  const RunFolderAgent({
    required this.settingsRepository,
    required this.inferenceRepository,
    required this.catalogRepository,
    required this.getEmails,
    required this.getEmail,
    required this.searchEmails,
    required this.getMailFolders,
    required this.getRawEmailBytes,
    required this.checkSenderAnomaly,
  });

  final AiSettingsRepository settingsRepository;
  final AiInferenceRepository inferenceRepository;
  final AiCatalogRepository catalogRepository;
  final GetEmails getEmails;
  final GetEmail getEmail;
  final SearchEmails searchEmails;
  final GetMailFolders getMailFolders;
  final GetRawEmailBytes getRawEmailBytes;
  final CheckSenderAnomaly checkSenderAnomaly;

  /// Most characters of the open email's text put in the system prompt; the
  /// model can still `get_email` the whole of a longer one.
  static const int maxOpenEmailChars = 8000;

  /// Default maximum streamed rounds per turn (one round = one model stream
  /// that may end in tool calls). Bounds runaway tool loops. Used when the
  /// configured [AiSettingsRepository.getAgentMaxRounds] value is unavailable.
  static const int defaultMaxRounds = 5;

  /// Default maximum tool calls executed per round. Calls beyond this are
  /// answered with an error result (so every assistant tool call still has a
  /// matching `tool`-role reply, as wire protocols require). Used when the
  /// configured [AiSettingsRepository.getAgentMaxToolCallsPerRound] value is
  /// unavailable.
  static const int defaultMaxToolCallsPerRound = 8;

  /// Sentinel `finishReason` on a transient tool-activity chunk. The chunk's
  /// `delta` carries a human-readable label (e.g. `Searching for "..."`) and
  /// its `toolCalls` the originating call. The presentation layer surfaces this
  /// as a transient activity label rather than appending it to the answer text.
  static const String toolActivityFinishReason =
      AgentLoop.toolActivityFinishReason;

  /// Sentinel `finishReason` on a tool-result chunk, emitted after a tool call
  /// has executed. The chunk's [AiChunk.toolResult] carries the originating
  /// call id, the serialized output, and whether the outcome was an error. The
  /// presentation layer matches it to the running tool card by `callId`.
  static const String toolResultFinishReason =
      AgentLoop.toolResultFinishReason;

  /// Agent system prompt — a tool-using variant of the folder-assistant prompt.
  static const String _agentSystemPrompt =
      'You are an email assistant embedded in a desktop mail client, operating '
      'as a tool-using agent. You have read-only tools to list, search, and '
      'read the user\'s mail and folders. Use them to gather the specific '
      'information you need before answering — do not guess or fabricate. '
      'Prefer list_emails or search_emails to find relevant messages, then '
      'get_email to read details. The user is currently viewing a specific '
      'folder; tools default to that folder when no folder is specified. When '
      'the user asks you to find emails and you narrow what a search or '
      'listing found down to the ones that match, finish by calling '
      'show_emails with their ids so the user can open them in their list. '
      'When asked whether an email is safe, phishing, spam, a scam or '
      'malicious, call check_email_safety on it and base the answer on that '
      'evidence. '
      'Cite specific senders, subjects, and dates. Be concise and specific.';

  /// Fallback system prompt (no tools) — mirrors [QueryEmailFolder].
  static const String _fallbackSystemPrompt =
      'You are an email assistant embedded in a desktop mail client. '
      'Help the user understand, manage, and triage their emails. '
      'When given a list of emails from a folder, use that context to answer '
      'questions, provide summaries, identify urgent items, and help the user '
      'prioritise their inbox. Be concise and specific.';

  /// Runs one agent turn.
  ///
  /// [history] is the prior conversation (user/assistant/tool turns) excluding
  /// the system prompt; [userInstruction] is the new user turn. [currentFolderId]
  /// is the panel's current folder (tool default). [selectedEmailId] is the
  /// message open in the reading pane, if any, and [accountId] the account
  /// the panel is on (for the lookalike-sender check). [fallbackEmailsContext]
  /// is the pre-formatted folder excerpt used only on the no-tools fallback
  /// path.
  Stream<Either<Failure, AiChunk>> call({
    required List<AiMessage> history,
    required String userInstruction,
    String? currentFolderId,
    String? selectedEmailId,
    String? accountId,
    String? fallbackEmailsContext,
  }) async* {
    // Resolve which provider + model handles the folder agent.
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

    // Privacy guard, computed once (§4): treat an unresolved provider as cloud.
    final provider = (await catalogRepository.getProvider(routing.providerId))
        .fold((_) => null, (value) => value);
    final allowCloud = (await settingsRepository.getAllowCloudForBodies())
        .getOrElse((_) => false);
    final isCloud = provider == null || provider.kind == AiProviderKind.cloud;
    final includeBodies = !isCloud || allowCloud;

    // Configurable safety bounds (§3): fall back to the compile-time defaults
    // if the setting can't be read.
    final maxRounds = (await settingsRepository.getAgentMaxRounds())
        .getOrElse((_) => defaultMaxRounds);
    final maxToolCallsPerRound =
        (await settingsRepository.getAgentMaxToolCallsPerRound())
            .getOrElse((_) => defaultMaxToolCallsPerRound);

    // Decide whether to run the tool-calling agent loop or the no-tools
    // fallback. Tool capability is only published by the models.dev catalog,
    // which backs cloud providers. For a BYO/local endpoint (Ollama, LM Studio,
    // vLLM…) models are discovered live and carry no capability metadata, so
    // their catalog `toolCall` flag defaults to false — that means "unknown",
    // not "unsupported". Trust the catalog flag for cloud providers; for
    // non-cloud providers optimistically attempt tools (the user's own endpoint
    // typically supports them, and one that does not simply ignores the `tools`
    // parameter). An unresolved provider is treated as cloud → conservative.
    final model = (await catalogRepository.getModel(
      providerId: routing.providerId,
      modelId: routing.modelId,
    ))
        .fold((_) => null, (value) => value);
    final toolCapable = isCloud ? (model?.toolCall ?? false) : true;

    // A message that can no longer be read (deleted, another account's) is
    // left out rather than failing the turn.
    final selected = selectedEmailId == null
        ? null
        : (await getEmail(GetEmailParams(id: selectedEmailId))).fold(
            (failure) {
              // Otherwise indistinguishable from the agent not knowing.
              debugPrint('[AI] open email $selectedEmailId left out of the '
                  'prompt: ${failure.message}');
              return null;
            },
            (email) => email,
          );
    final openEmail = selected == null
        ? ''
        : '\n\n${_openEmailSection(selected, includeBodies)}';

    // --- Fallback: no-tools, pre-stuffed context (mirrors QueryEmailFolder) --
    if (!toolCapable) {
      final request = AiRequest(
        providerId: routing.providerId,
        modelId: routing.modelId,
        stream: true,
        messages: [
          AiMessage(
            role: AiRole.system,
            content: '$_fallbackSystemPrompt$openEmail',
          ),
          ...history,
          AiMessage(
            role: AiRole.user,
            content: _buildFallbackPrompt(
              instruction: userInstruction,
              emailsContext: includeBodies ? fallbackEmailsContext : null,
            ),
          ),
        ],
      );
      yield* inferenceRepository.stream(request);
      return;
    }

    // --- Agent loop --------------------------------------------------------
    final tools = <AgentTool>[
      ListEmailsTool(getEmails),
      GetEmailTool(getEmail, includeBodies: includeBodies),
      SearchEmailsTool(searchEmails),
      ListFoldersTool(getMailFolders),
      CheckEmailSafetyTool(
        getEmail,
        getRawEmailBytes,
        checkSenderAnomaly,
        accountId: accountId,
      ),
      ShowEmailsTool(getEmail),
    ];
    // The loop itself is shared with the commitments agent — see AgentLoop.
    yield* AgentLoop(inferenceRepository).run(
      routing: routing,
      systemPrompt: '$_agentSystemPrompt$openEmail',
      tools: tools,
      history: history,
      userInstruction: userInstruction,
      currentFolderId: currentFolderId,
      maxRounds: maxRounds,
      maxToolCallsPerRound: maxToolCallsPerRound,
      activityLabel: _activityLabel,
    );
  }

  /// The system-prompt paragraph naming the message open in the reading pane.
  /// Its text is included only when bodies may go to this provider, cut to
  /// [maxOpenEmailChars]; otherwise the preview stands in, as `get_email`.
  String _openEmailSection(Email email, bool includeBodies) {
    final from = email.from.name == null || email.from.name!.isEmpty
        ? email.from.address
        : '${email.from.name} <${email.from.address}>';
    final buffer = StringBuffer()
      ..writeln('The user has this email open in the reading pane. When they '
          'say "this email", "this message", "the selected email" or ask about '
          'an email without saying which, they mean this one — do not search '
          'for another.')
      ..writeln('id: ${email.id}')
      ..writeln('From: $from')
      ..writeln('Subject: ${email.subject}')
      ..writeln('Date: ${email.receivedDateTime.toIso8601String()}');
    if (includeBodies) {
      final text = (email.bodyType == EmailBodyType.html
              ? htmlToPlainText(email.body)
              : email.body)
          .trim();
      final cut = text.length > maxOpenEmailChars
          ? '${text.substring(0, maxOpenEmailChars)}\n[… truncated — call '
              'get_email for the rest]'
          : text;
      buffer
        ..writeln('Body:')
        ..write(cut);
    } else {
      buffer.write('Preview: ${email.bodyPreview}');
    }
    return buffer.toString();
  }

  /// Combines the user's [instruction] with any [emailsContext] into a single
  /// user-turn prompt (no-tools fallback). Mirrors [QueryEmailFolder].
  String _buildFallbackPrompt({
    required String instruction,
    String? emailsContext,
  }) {
    final ctx = emailsContext?.trim();
    if (ctx == null || ctx.isEmpty) return instruction.trim();
    return 'Emails in folder:\n$ctx\n\nInstruction:\n${instruction.trim()}';
  }

  /// A short, human-readable label for a tool call, surfaced transiently in the
  /// UI while the tool runs.
  String _activityLabel(AiToolCall call) {
    switch (call.name) {
      case 'list_emails':
        return 'Listing emails…';
      case 'search_emails':
        final query = call.arguments['query'];
        return query is String && query.isNotEmpty
            ? 'Searching for "$query"…'
            : 'Searching emails…';
      case 'get_email':
        return 'Reading an email…';
      case 'list_folders':
        return 'Listing folders…';
      case 'check_email_safety':
        return 'Checking the email\'s security signals…';
      case 'show_emails':
        return 'Picking out the matching emails…';
      default:
        return 'Using ${call.name}…';
    }
  }
}
