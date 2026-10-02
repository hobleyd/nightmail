import 'dart:convert';

import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';
import '../../../entities/ai/ai_chunk.dart';
import '../../../entities/ai/ai_message.dart';
import '../../../entities/ai/ai_request.dart';
import '../../../entities/ai/ai_tool_call.dart';
import '../../../entities/ai/ai_tool_definition.dart';
import '../../../entities/ai/ai_tool_result.dart';
import '../../../repositories/ai/ai_inference_repository.dart';
import '../../../repositories/ai/ai_settings_repository.dart';
import 'agent_tool.dart';

/// The tool-calling loop every agent in the app runs: stream a model turn,
/// execute the tool calls it ends with, feed the results back, repeat until
/// the model answers in text or the round cap is hit.
///
/// Extracted from the folder agent so the commitments agent (natural-language
/// control over the ledger) runs the same loop with different tools and a
/// different prompt. Callers own routing, prompt and tools; the loop owns
/// the wire discipline: every tool call gets a `tool`-role reply (even a
/// skipped or unknown one), a tool `Left` is serialised into its result so
/// the model can recover, and a hard provider failure aborts the turn as a
/// single terminal `Left`.
///
/// Two sentinel finish reasons mark the transient events the presentation
/// layer renders as tool cards: [toolActivityFinishReason] when a call starts
/// (the chunk's `delta` is a human label, `toolCalls` the call) and
/// [toolResultFinishReason] when it finishes (`toolResult` carries the
/// output).
class AgentLoop {
  const AgentLoop(this.inferenceRepository);

  final AiInferenceRepository inferenceRepository;

  static const String toolActivityFinishReason = 'tool_activity';
  static const String toolResultFinishReason = 'tool_result';

  Stream<Either<Failure, AiChunk>> run({
    required AiRouting routing,
    required String systemPrompt,
    required List<AgentTool> tools,
    required List<AiMessage> history,
    required String userInstruction,
    String? currentFolderId,
    required int maxRounds,
    required int maxToolCallsPerRound,
    required String Function(AiToolCall call) activityLabel,
  }) async* {
    final toolsByName = {for (final t in tools) t.name: t};
    final toolDefs = tools
        .map((t) => AiToolDefinition(
              name: t.name,
              description: t.description,
              parametersSchema: t.parametersSchema,
            ))
        .toList();

    final messages = <AiMessage>[
      AiMessage(role: AiRole.system, content: systemPrompt),
      ...history,
      AiMessage(role: AiRole.user, content: userInstruction),
    ];

    for (var round = 0; round < maxRounds; round++) {
      final request = AiRequest(
        providerId: routing.providerId,
        modelId: routing.modelId,
        stream: true,
        messages: List.unmodifiable(messages),
        tools: toolDefs,
      );

      List<AiToolCall>? roundToolCalls;

      await for (final event in inferenceRepository.stream(request)) {
        final failure = event.getLeft().toNullable();
        if (failure != null) {
          // Hard provider failure aborts the turn.
          yield Left(failure);
          return;
        }
        final chunk = event.getRight().toNullable()!;
        if (chunk.toolCalls != null && chunk.toolCalls!.isNotEmpty) {
          // Capture the round-terminal tool calls; do not forward the
          // round-terminal chunk (the turn is not over yet).
          roundToolCalls = chunk.toolCalls;
        } else {
          // Pass text deltas (and a genuine no-tools terminal chunk) through.
          yield event;
        }
      }

      // No tool calls → the final answer has already been streamed.
      if (roundToolCalls == null || roundToolCalls.isEmpty) return;

      // Record the assistant turn that requested the tools.
      messages.add(
        AiMessage(
          role: AiRole.assistant,
          content: '',
          toolCalls: roundToolCalls,
        ),
      );

      // Execute each call, emit a transient activity chunk, and append the
      // result as a `tool`-role turn. Every call gets a matching reply.
      for (var i = 0; i < roundToolCalls.length; i++) {
        final call = roundToolCalls[i];

        yield Right(
          AiChunk(
            delta: activityLabel(call),
            finishReason: toolActivityFinishReason,
            toolCalls: [call],
          ),
        );

        final String resultString;
        final bool isError;
        if (i >= maxToolCallsPerRound) {
          resultString = jsonEncode({
            'error': 'Tool call skipped: per-round tool-call limit reached.',
          });
          isError = true;
        } else {
          final tool = toolsByName[call.name];
          if (tool == null) {
            resultString = jsonEncode({'error': "Unknown tool '${call.name}'."});
            isError = true;
          } else {
            // Serialize a tool Left into the result so the model can recover.
            final outcome = await tool.invoke(
              call.arguments,
              currentFolderId: currentFolderId,
            );
            isError = outcome.isLeft();
            resultString = outcome.fold(
              (failure) => jsonEncode({'error': failure.message}),
              (value) => value,
            );
          }
        }

        messages.add(
          AiMessage(
            role: AiRole.tool,
            content: resultString,
            toolCallId: call.id,
            name: call.name,
          ),
        );

        // Finished event: carries the structured result so the UI can update
        // the running tool card to complete/error with its output.
        yield Right(
          AiChunk(
            delta: '',
            finishReason: toolResultFinishReason,
            toolResult: AiToolResult(
              callId: call.id,
              output: resultString,
              isError: isError,
            ),
          ),
        );
      }
      // Loop to let the model read the results and either answer or call more.
    }

    // Max rounds exceeded without a final answer.
    yield const Right(
      AiChunk(
        delta: '\n\n_(Reached the maximum number of tool steps for this '
            'turn. Ask a follow-up to continue.)_',
        done: true,
        finishReason: 'max_rounds',
      ),
    );
  }
}
