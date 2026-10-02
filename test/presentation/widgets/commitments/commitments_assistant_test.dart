import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_call.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_result.dart';
import 'package:nightmail/domain/usecases/ai/agent/agent_loop.dart';
import 'package:nightmail/domain/usecases/commitments/agent/commitment_agent_tools.dart';
import 'package:nightmail/domain/usecases/commitments/run_commitments_agent.dart';
import 'package:nightmail/presentation/blocs/commitments/commitments_agent_cubit.dart';
import 'package:nightmail/presentation/widgets/ai/tool_call_card.dart';
import 'package:nightmail/presentation/widgets/commitments/commitments_assistant.dart';

import 'commitments_assistant_test.mocks.dart';

/// The natural-language control chat over a real [CommitmentsAgentCubit]
/// with the agent mocked: examples while empty, a turn that renders a tool
/// card and an answer, and the reload hook once the turn settles.
@GenerateMocks([RunCommitmentsAgent])
void main() {
  late MockRunCommitmentsAgent runAgent;
  late int reloads;

  final snapshot = CommitmentsAgentSnapshot(
    accountId: 'acc',
    commitments: const [],
    events: const [],
    taskDueDates: const [],
    now: DateTime(2026, 10, 6, 9),
  );

  setUp(() {
    runAgent = MockRunCommitmentsAgent();
    reloads = 0;
  });

  CommitmentsAgentCubit buildCubit({bool withAccount = true}) =>
      CommitmentsAgentCubit(
        runAgent: runAgent,
        snapshot: () => withAccount ? snapshot : null,
        onChanged: () async => reloads++,
      );

  Future<void> pump(WidgetTester tester, CommitmentsAgentCubit cubit,
      {bool compact = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: compact
                ? Align(
                    alignment: Alignment.bottomCenter,
                    child: SizedBox(
                      width: 420,
                      child: CommitmentsAssistant(compact: true),
                    ),
                  )
                : SizedBox(
                    width: 360,
                    height: 600,
                    child: CommitmentsAssistant(compact: false),
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Stream<Either<Failure, AiChunk>> turn() => Stream.fromIterable([
        const Right(AiChunk(
          delta: 'Reading the ledger…',
          finishReason: AgentLoop.toolActivityFinishReason,
          toolCalls: [AiToolCall(id: 'c1', name: 'list_commitments', arguments: {})],
        )),
        const Right(AiChunk(
          delta: '',
          finishReason: AgentLoop.toolResultFinishReason,
          toolResult: AiToolResult(callId: 'c1', output: '{"count":0}', isError: false),
        )),
        const Right(AiChunk(delta: 'Nothing is open, so there was nothing to move.')),
        const Right(AiChunk(delta: '', done: true, finishReason: 'stop')),
      ]);

  testWidgets('compact: offers examples, runs a turn, shows the card and the '
      'answer, then asks for a reload', (tester) async {
    when(runAgent.call(
      history: anyNamed('history'),
      userInstruction: anyNamed('userInstruction'),
      snapshot: anyNamed('snapshot'),
    )).thenAnswer((_) => turn());
    final cubit = buildCubit();
    addTearDown(cubit.close);
    await pump(tester, cubit);

    // Empty: just the input bar; the examples live in the transcript area,
    // which the compact layout only unfolds once there is a transcript.
    expect(find.text('Tell me what to change…'), findsOneWidget);
    expect(find.byType(ToolCallCard), findsNothing);

    await tester.enterText(find.byType(TextField), 'Move everything non-urgent to Friday');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    final captured = verify(runAgent.call(
      history: captureAnyNamed('history'),
      userInstruction: captureAnyNamed('userInstruction'),
      snapshot: captureAnyNamed('snapshot'),
    )).captured;
    expect(captured[0], isEmpty); // first turn: no history
    expect(captured[1], 'Move everything non-urgent to Friday');
    expect(captured[2], same(snapshot));

    expect(find.text('Move everything non-urgent to Friday'), findsOneWidget);
    expect(find.byType(ToolCallCard), findsOneWidget);
    expect(find.text('Nothing is open, so there was nothing to move.'), findsOneWidget);
    expect(reloads, 1);
    // The input is clear and usable again; the clear-conversation action appears.
    expect((tester.widget(find.byType(TextField)) as TextField).controller!.text, isEmpty);
    expect(find.byTooltip('Clear conversation'), findsOneWidget);
  });

  testWidgets('wide: the examples are visible up front and an example sends',
      (tester) async {
    when(runAgent.call(
      history: anyNamed('history'),
      userInstruction: anyNamed('userInstruction'),
      snapshot: anyNamed('snapshot'),
    )).thenAnswer((_) => turn());
    final cubit = buildCubit();
    addTearDown(cubit.close);
    await pump(tester, cubit, compact: false);

    expect(find.text('ASSISTANT'), findsOneWidget);
    for (final e in CommitmentsAssistant.examples) {
      expect(find.text(e), findsOneWidget, reason: e);
    }

    await tester.tap(find.text('What is overloaded this week?'));
    await tester.pumpAndSettle();

    verify(runAgent.call(
      history: anyNamed('history'),
      userInstruction: 'What is overloaded this week?',
      snapshot: anyNamed('snapshot'),
    )).called(1);
  });

  testWidgets('a provider failure is shown in the transcript', (tester) async {
    when(runAgent.call(
      history: anyNamed('history'),
      userInstruction: anyNamed('userInstruction'),
      snapshot: anyNamed('snapshot'),
    )).thenAnswer((_) => Stream.value(
          const Left(UnsupportedFailure(message: 'The Compose model cannot call tools')),
        ));
    final cubit = buildCubit();
    addTearDown(cubit.close);
    await pump(tester, cubit);

    await tester.enterText(find.byType(TextField), 'Do something');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot call tools'), findsOneWidget);
    expect(reloads, 1); // a failed turn still ends the turn
  });

  testWidgets('without an account the send is refused with a message',
      (tester) async {
    final cubit = buildCubit(withAccount: false);
    addTearDown(cubit.close);
    await pump(tester, cubit);

    await tester.enterText(find.byType(TextField), 'Do something');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Sign in to an account'), findsOneWidget);
    verifyNever(runAgent.call(
      history: anyNamed('history'),
      userInstruction: anyNamed('userInstruction'),
      snapshot: anyNamed('snapshot'),
    ));
  });

  test('history carries earlier turns to the next one', () async {
    when(runAgent.call(
      history: anyNamed('history'),
      userInstruction: anyNamed('userInstruction'),
      snapshot: anyNamed('snapshot'),
    )).thenAnswer((_) => turn());
    final cubit = buildCubit();
    addTearDown(cubit.close);

    // The mocked turn completes within a few microtasks, so poll the state
    // rather than await the stream — the idle emission may already be gone.
    Future<void> settle() async {
      for (var i = 0; i < 50 && cubit.state.isStreaming; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(cubit.state.isStreaming, isFalse);
    }

    cubit.send('first');
    await settle();
    cubit.send('second');
    await settle();

    final histories = verify(runAgent.call(
      history: captureAnyNamed('history'),
      userInstruction: anyNamed('userInstruction'),
      snapshot: anyNamed('snapshot'),
    )).captured.cast<List<AiMessage>>();
    expect(histories[0], isEmpty);
    expect(histories[1].map((m) => (m.role, m.content)), [
      (AiRole.user, 'first'),
      (AiRole.assistant, 'Nothing is open, so there was nothing to move.'),
    ]);
  });
}
