import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/entities/ai/compose_draft_snapshot.dart';
import 'package:nightmail/domain/usecases/ai/run_compose_assistant.dart';
import 'package:nightmail/presentation/blocs/ai/ai_folder_chat_state.dart';
import 'package:nightmail/presentation/blocs/ai/compose_assistant_cubit.dart';

import 'compose_assistant_cubit_test.mocks.dart';

@GenerateMocks([RunComposeAssistant])
void main() {
  late MockRunComposeAssistant mockRun;
  late List<ComposeDraftSnapshot?> snapshots;
  late int snapshotReads;
  late ComposeAssistantCubit cubit;

  setUp(() {
    provideDummy<Stream<Either<Failure, AiChunk>>>(
      const Stream<Either<Failure, AiChunk>>.empty(),
    );
    mockRun = MockRunComposeAssistant();
    snapshots = [];
    snapshotReads = 0;
    cubit = ComposeAssistantCubit(
      runAssistant: mockRun,
      snapshot: () async => snapshots[snapshotReads++],
    );
    when(mockRun.call(
      history: anyNamed('history'),
      userInstruction: anyNamed('userInstruction'),
      snapshot: anyNamed('snapshot'),
    )).thenAnswer((_) => Stream.fromIterable(const [
          Right(AiChunk(delta: 'Sure.', done: true, finishReason: 'stop')),
        ]));
  });

  tearDown(() => cubit.close());

  test('reads the draft afresh for every turn', () async {
    snapshots = const [
      ComposeDraftSnapshot(draft: 'first version'),
      ComposeDraftSnapshot(draft: 'edited by hand since'),
    ];

    await cubit.send('Review it');
    await pumpEventQueue();
    await cubit.send('And now?');
    await pumpEventQueue();

    final seen = verify(mockRun.call(
      history: anyNamed('history'),
      userInstruction: anyNamed('userInstruction'),
      snapshot: captureAnyNamed('snapshot'),
    )).captured.cast<ComposeDraftSnapshot>();
    expect(seen.map((s) => s.draft), ['first version', 'edited by hand since']);
    expect(
      cubit.state.messages.whereType<AiTextMessage>().map((m) => m.text),
      ['Review it', 'Sure.', 'And now?', 'Sure.'],
    );
  });

  test(
      'an unreadable draft refuses the turn with a message safe to show, and '
      'never asks the model', () async {
    snapshots = const [null];

    await cubit.send('Review it');

    expect(cubit.state.failure, isA<UnsupportedFailure>());
    expect(cubit.state.failure!.message,
        ComposeAssistantCubit.unreadableDraftMessage);
    // The user still sees what they sent, with the reason after it.
    expect(
      cubit.state.messages.whereType<AiTextMessage>().map((m) => m.text),
      ['Review it'],
    );
    verifyNever(mockRun.call(
      history: anyNamed('history'),
      userInstruction: anyNamed('userInstruction'),
      snapshot: anyNamed('snapshot'),
    ));
  });

  test('a second send while the draft is still being read is ignored',
      () async {
    final gate = Completer<ComposeDraftSnapshot?>();
    await cubit.close();
    cubit = ComposeAssistantCubit(
      runAssistant: mockRun,
      snapshot: () {
        snapshotReads++;
        return gate.future;
      },
    );

    final first = cubit.send('one');
    final second = cubit.send('two');
    gate.complete(const ComposeDraftSnapshot(draft: 'x'));
    await Future.wait([first, second]);
    await pumpEventQueue();

    expect(snapshotReads, 1);
    verify(mockRun.call(
      history: anyNamed('history'),
      userInstruction: 'one',
      snapshot: anyNamed('snapshot'),
    )).called(1);
  });
}
