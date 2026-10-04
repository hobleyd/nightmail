import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../entities/ai/ai_capability.dart';
import '../../entities/ai/ai_chunk.dart';
import '../../entities/ai/ai_message.dart';
import '../../entities/ai/ai_provider.dart';
import '../../entities/ai/ai_tool_call.dart';
import '../../repositories/ai/ai_catalog_repository.dart';
import '../../repositories/ai/ai_inference_repository.dart';
import '../../repositories/ai/ai_settings_repository.dart';
import '../../repositories/commitment_repository.dart';
import '../ai/agent/agent_loop.dart';
import '../ai/agent/agent_tool.dart';
import '../ai/run_folder_agent.dart';
import 'agent/commitment_agent_tools.dart';
import 'forecast_workload.dart';
import 'schedule_commitment.dart';
import 'suggest_time_block.dart';

/// Natural-language control over the commitments ledger: "Move everything
/// non-urgent until Friday and give me two hours for the AWS work."
///
/// A tool-calling agent on the model routed to [AiCapability.compose] (the
/// same route the folder agent uses), with tools over the ledger and the
/// week ahead — list, forecast, find a free slot, the planner's suggestion,
/// schedule or move a block, mark done, dismiss. The instruction becomes a
/// sequence of real tool calls, each shown as a card in the transcript, and
/// the answer reports what changed with days and times.
///
/// Unlike the folder agent there is no no-tools fallback: control without
/// tools would be a model *describing* changes it cannot make, so a model
/// that cannot call tools fails closed with an [UnsupportedFailure] that
/// says what to route Compose to.
class RunCommitmentsAgent {
  const RunCommitmentsAgent({
    required this.settingsRepository,
    required this.inferenceRepository,
    required this.catalogRepository,
    required this.scheduleCommitment,
    required this.commitmentRepository,
    this.suggester = const SuggestTimeBlock(),
    this.forecaster = const ForecastWorkload(),
  });

  final AiSettingsRepository settingsRepository;
  final AiInferenceRepository inferenceRepository;
  final AiCatalogRepository catalogRepository;
  final ScheduleCommitment scheduleCommitment;
  final CommitmentRepository commitmentRepository;
  final SuggestTimeBlock suggester;
  final ForecastWorkload forecaster;

  static const String toolActivityFinishReason =
      AgentLoop.toolActivityFinishReason;
  static const String toolResultFinishReason = AgentLoop.toolResultFinishReason;

  Stream<Either<Failure, AiChunk>> call({
    required List<AiMessage> history,
    required String userInstruction,
    required CommitmentsAgentSnapshot snapshot,
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
        NoProviderConfigured(
          message: 'Natural-language control uses the Compose model. Route '
              'Compose to a tool-capable chat model in Settings › AI.',
        ),
      );
      return;
    }

    // Tool capability, judged as the folder agent judges it: trust the
    // catalog flag for a cloud provider, assume a local/BYO endpoint can.
    final provider = (await catalogRepository.getProvider(routing.providerId))
        .fold((_) => null, (p) => p);
    final isCloud = provider == null || provider.kind == AiProviderKind.cloud;
    final model = (await catalogRepository.getModel(
      providerId: routing.providerId,
      modelId: routing.modelId,
    ))
        .fold((_) => null, (m) => m);
    final toolCapable = isCloud ? (model?.toolCall ?? false) : true;
    if (!toolCapable) {
      yield const Left(
        UnsupportedFailure(
          message: 'The Compose model cannot call tools, and changing the '
              'schedule needs tools. Route Compose to a tool-capable chat '
              'model in Settings › AI.',
        ),
      );
      return;
    }

    final maxRounds = (await settingsRepository.getAgentMaxRounds())
        .getOrElse((_) => RunFolderAgent.defaultMaxRounds);
    final maxToolCallsPerRound =
        (await settingsRepository.getAgentMaxToolCallsPerRound())
            .getOrElse((_) => RunFolderAgent.defaultMaxToolCallsPerRound);

    final tools = buildCommitmentTools(CommitmentToolContext(
      snapshot: snapshot,
      scheduler: scheduleCommitment,
      ledger: commitmentRepository,
      suggester: suggester,
      forecaster: forecaster,
    ));

    yield* AgentLoop(inferenceRepository).run(
      routing: routing,
      systemPrompt: systemPromptFor(snapshot.now, suggester),
      tools: tools,
      history: history,
      userInstruction: userInstruction,
      maxRounds: maxRounds,
      maxToolCallsPerRound: maxToolCallsPerRound,
      activityLabel: activityLabel,
    );
  }

  /// The agent's instructions, with the clock and working hours it must
  /// reason against — a model has no idea what day it is otherwise.
  static String systemPromptFor(DateTime now, SuggestTimeBlock suggester) {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${weekdays[now.weekday - 1]} ${now.year}-${two(now.month)}-'
        '${two(now.day)} ${two(now.hour)}:${two(now.minute)}';
    return 'You are the scheduling assistant inside a desktop mail client, '
        'operating as a tool-using agent over the user\'s commitments: '
        'promises they made in mail (i_owe), things others owe them '
        '(they_owe_me) and received mail that needs a decision '
        '(needs_action). Each commitment can have one time block on the '
        'calendar, and carries estimated_minutes — the model\'s reading of '
        'how long it needs — which is the block length to use unless the '
        'user names one.\n\n'
        'It is now $stamp, local time. Working hours are '
        '${suggester.workingDayStartHour}:00–${suggester.workingDayEndHour}:00, '
        'Monday to Friday; blocks start on ${suggester.slotMinutes}-minute '
        'boundaries. All times you pass to tools are local ISO 8601 '
        '(2026-10-08T14:00).\n\n'
        'Method: call list_commitments first and work only with the ids it '
        'returns — never invent one. Use get_forecast to see which days are '
        'light or overloaded, find_free_slot or suggest_block to pick a '
        'start, then schedule_block to book or move. "Non-urgent" means '
        'urgency 0 or 1 and not overdue; "urgent" means urgency 2 or '
        'overdue. "Until Friday" / "to Thursday" means move the blocks (or '
        'give unscheduled items blocks) on that day, in free slots. "Give me '
        'N hours for X" means find the commitment whose subject or '
        'counterpart matches X and block N hours for it on the lightest '
        'suitable day. Never move an item past its due day. Do what was '
        'asked without asking for confirmation unless the instruction is '
        'genuinely ambiguous between different commitments. Then answer in '
        'two or three short sentences listing exactly what changed, with '
        'weekday and time, and anything you could not do and why.';
  }

  /// A short, human-readable label for a tool call while it runs.
  static String activityLabel(AiToolCall call) {
    switch (call.name) {
      case 'list_commitments':
        return 'Reading the ledger…';
      case 'get_forecast':
        return 'Looking at the week ahead…';
      case 'find_free_slot':
        final day = call.arguments['day'];
        return day is String ? 'Finding a free slot on $day…' : 'Finding a free slot…';
      case 'suggest_block':
        return 'Picking a time…';
      case 'schedule_block':
        return 'Blocking time…';
      case 'mark_done':
        return 'Marking done…';
      case 'dismiss':
        return 'Dismissing…';
      default:
        return 'Using ${call.name}…';
    }
  }
}

/// Exposed for tests: the tool names the agent advertises.
List<String> commitmentAgentToolNames(CommitmentToolContext ctx) =>
    [for (final AgentTool t in buildCommitmentTools(ctx)) t.name];
