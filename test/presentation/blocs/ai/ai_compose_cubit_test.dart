import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/usecases/ai/compose_reply.dart';
import 'package:nightmail/presentation/blocs/ai/ai_compose_cubit.dart';
import 'package:nightmail/presentation/blocs/ai/ai_compose_state.dart';

import 'ai_compose_cubit_test.mocks.dart';

// We mock the ComposeReply use case directly and feed its
// `Stream<Either<Failure, AiChunk>>` from a StreamController so the test owns
// the timing of every delta, the terminal chunk, errors, and stream-close.
@GenerateMocks([ComposeReply])
void main() {
  late AiComposeCubit cubit;
  late MockComposeReply mockComposeReply;
  late StreamController<Either<Failure, AiChunk>> controller;

  setUp(() {
    // Mockito cannot synthesise a dummy for ComposeReply.call's non-nullable
    // Stream return type, so register an empty one for any unstubbed call.
    provideDummy<Stream<Either<Failure, AiChunk>>>(
      const Stream<Either<Failure, AiChunk>>.empty(),
    );

    mockComposeReply = MockComposeReply();
    cubit = AiComposeCubit(composeReply: mockComposeReply);

    // Broadcast-free single controller per test; the cubit attaches exactly one
    // listener, which lets us assert subscription teardown via `hasListener`.
    controller = StreamController<Either<Failure, AiChunk>>();
  });

  tearDown(() async {
    await cubit.close();
    if (!controller.isClosed) await controller.close();
  });

  /// Stub the use case to return our controller's stream for this test.
  void stubStream() {
    when(mockComposeReply.call(
      instruction: anyNamed('instruction'),
      originalMessage: anyNamed('originalMessage'),
    )).thenAnswer((_) => controller.stream);
  }

  group('AiComposeCubit.generate', () {
    test(
        'accumulates streamed deltas into AiComposeStreaming and settles on '
        'AiComposeDone (with usage) at the terminal chunk', () async {
      stubStream();

      final states = <AiComposeState>[];
      final sub = cubit.stream.listen(states.add);

      cubit.generate('Write a reply', context: 'Original email');
      controller.add(const Right(AiChunk(delta: 'Hello')));
      controller.add(const Right(AiChunk(delta: ' world')));
      controller.add(const Right(AiChunk(
        delta: '!',
        done: true,
        finishReason: 'stop',
        promptTokens: 12,
        completionTokens: 4,
      )));
      await pumpEventQueue();

      expect(states, const [
        AiComposeStreaming(text: ''),
        AiComposeStreaming(text: 'Hello'),
        AiComposeStreaming(text: 'Hello world'),
        AiComposeDone(
          text: 'Hello world!',
          finishReason: 'stop',
          promptTokens: 12,
          completionTokens: 4,
        ),
      ]);

      // The instruction + quoted context are forwarded verbatim to the use case.
      verify(mockComposeReply.call(
        instruction: 'Write a reply',
        originalMessage: 'Original email',
      )).called(1);

      // The terminal chunk must have torn the subscription down.
      expect(controller.hasListener, isFalse);

      await sub.cancel();
    });

    test('emits AiComposeError and cancels the subscription on a Left failure',
        () async {
      stubStream();

      final states = <AiComposeState>[];
      final sub = cubit.stream.listen(states.add);

      cubit.generate('Draft something');
      controller.add(const Right(AiChunk(delta: 'partial draft')));
      controller.add(
        const Left(ProviderUnreachable(message: '502 Bad Gateway')),
      );
      await pumpEventQueue();

      expect(states, const [
        AiComposeStreaming(text: ''),
        AiComposeStreaming(text: 'partial draft'),
        AiComposeError(failure: ProviderUnreachable(message: '502 Bad Gateway')),
      ]);
      // Failure path must cancel the in-flight stream.
      expect(controller.hasListener, isFalse);

      await sub.cancel();
    });

    test(
        'onDone safety-net settles AiComposeStreaming on AiComposeDone when the '
        'stream closes without a terminal chunk', () async {
      stubStream();

      final states = <AiComposeState>[];
      final sub = cubit.stream.listen(states.add);

      cubit.generate('Reply please');
      controller.add(const Right(AiChunk(delta: 'unfinished')));
      await pumpEventQueue();
      // Provider closed the stream mid-flight without a done==true chunk.
      await controller.close();
      await pumpEventQueue();

      expect(states, const [
        AiComposeStreaming(text: ''),
        AiComposeStreaming(text: 'unfinished'),
        // No finishReason / usage because there was no terminal chunk.
        AiComposeDone(text: 'unfinished'),
      ]);

      await sub.cancel();
    });

    test(
        'a clean stream-close after the terminal chunk does not double-emit '
        '(onDone is a no-op once settled)', () async {
      stubStream();

      final states = <AiComposeState>[];
      final sub = cubit.stream.listen(states.add);

      cubit.generate('Reply');
      controller.add(const Right(AiChunk(delta: 'done text', done: true)));
      await pumpEventQueue();
      // Closing afterwards must NOT produce a second AiComposeDone — state is no
      // longer AiComposeStreaming, so the onDone safety-net stays inert.
      await controller.close();
      await pumpEventQueue();

      expect(states, const [
        AiComposeStreaming(text: ''),
        AiComposeDone(text: 'done text'),
      ]);

      await sub.cancel();
    });

    test('a new generate() cancels the previous in-flight subscription',
        () async {
      // First run uses our controller; the second run uses a fresh one.
      final secondController =
          StreamController<Either<Failure, AiChunk>>();
      addTearDown(() async {
        if (!secondController.isClosed) await secondController.close();
      });
      when(mockComposeReply.call(
        instruction: anyNamed('instruction'),
        originalMessage: anyNamed('originalMessage'),
      )).thenAnswer((invocation) {
        return invocation.namedArguments[#instruction] == 'first'
            ? controller.stream
            : secondController.stream;
      });

      cubit.generate('first');
      await pumpEventQueue();
      expect(controller.hasListener, isTrue);

      cubit.generate('second');
      await pumpEventQueue();
      // The first stream's subscription must have been cancelled.
      expect(controller.hasListener, isFalse);
      expect(secondController.hasListener, isTrue);
    });
  });

  group('AiComposeCubit.cancel', () {
    test('cancels the in-flight stream and returns to AiComposeIdle', () async {
      stubStream();

      final states = <AiComposeState>[];
      final sub = cubit.stream.listen(states.add);

      cubit.generate('Reply');
      controller.add(const Right(AiChunk(delta: 'half')));
      await pumpEventQueue();
      cubit.cancel();
      await pumpEventQueue();

      expect(states, const [
        AiComposeStreaming(text: ''),
        AiComposeStreaming(text: 'half'),
        AiComposeIdle(),
      ]);
      expect(controller.hasListener, isFalse);

      await sub.cancel();
    });
  });

  group('AiComposeCubit.close', () {
    test(
        'cancels the subscription so post-close deltas neither emit nor throw',
        () async {
      stubStream();

      cubit.generate('Reply');
      await pumpEventQueue();
      expect(controller.hasListener, isTrue);

      await cubit.close();
      await pumpEventQueue();

      // Subscription torn down by close(); the stream has no listener left.
      expect(controller.hasListener, isFalse);

      // Late deltas must be harmless — no emit-after-close, no exception.
      controller.add(const Right(AiChunk(delta: 'late', done: true)));
      await expectLater(controller.close(), completes);
      await pumpEventQueue();
    });
  });
}
