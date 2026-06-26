import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/ai/inference/anthropic_adapter.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_request.dart';
import 'package:nightmail/domain/entities/ai/ai_response.dart';

import 'anthropic_adapter_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late AnthropicAdapter adapter;

  setUp(() {
    // Mockito cannot synthesize dummy values for the Response<T> generics that
    // dio.post returns, so register them explicitly.
    provideDummy<Response<dynamic>>(
      Response<dynamic>(requestOptions: RequestOptions(path: '')),
    );
    provideDummy<Response<ResponseBody>>(
      Response<ResponseBody>(requestOptions: RequestOptions(path: '')),
    );

    mockDio = MockDio();
    adapter = AnthropicAdapter(dio: mockDio);
  });

  const baseUrl = 'https://api.anthropic.com';
  const apiKey = 'sk-ant-test-key';

  final tRequest = AiRequest(
    providerId: 'anthropic',
    modelId: 'claude-3-5-sonnet',
    maxTokens: 256,
    temperature: 0.5,
    messages: const [
      AiMessage(role: AiRole.system, content: 'You are helpful.'),
      AiMessage(role: AiRole.user, content: 'Hello there.'),
    ],
  );

  DioException dioErrorWithStatus(int status) => DioException(
        requestOptions: RequestOptions(path: '/v1/messages'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/v1/messages'),
          statusCode: status,
        ),
        type: DioExceptionType.badResponse,
      );

  group('run', () {
    test('parses an Anthropic Messages response into an AiResponse', () async {
      final responseJson = {
        'id': 'msg_123',
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Hello, world'},
        ],
        'stop_reason': 'end_turn',
        'usage': {'input_tokens': 11, 'output_tokens': 7},
      };

      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: responseJson,
          statusCode: 200,
          requestOptions: RequestOptions(path: '/v1/messages'),
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(
        result,
        const Right<Failure, AiResponse>(
          AiResponse(
            text: 'Hello, world',
            promptTokens: 11,
            completionTokens: 7,
            finishReason: 'end_turn',
          ),
        ),
      );
    });

    test('sends x-api-key / anthropic-version headers and hoists the '
        'system prompt out of messages', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: const {
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          },
          statusCode: 200,
          requestOptions: RequestOptions(path: '/v1/messages'),
        ),
      );

      await adapter.run(tRequest, apiKey: apiKey, baseUrl: baseUrl);

      final captured = verify(
        mockDio.post<dynamic>(
          captureAny,
          data: captureAnyNamed('data'),
          options: captureAnyNamed('options'),
        ),
      ).captured;

      final path = captured[0] as String;
      final body = captured[1] as Map<String, dynamic>;
      final options = captured[2] as Options;

      expect(path, '$baseUrl/v1/messages');

      // Headers.
      final headers = options.headers!;
      expect(headers['x-api-key'], apiKey);
      expect(headers['anthropic-version'], '2023-06-01');

      // System prompt hoisted to the top-level `system` field.
      expect(body['system'], 'You are helpful.');
      expect(body['model'], 'claude-3-5-sonnet');
      expect(body['max_tokens'], 256);

      // `messages` contains only the user/assistant turns (no system role).
      final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
      expect(messages, [
        {'role': 'user', 'content': 'Hello there.'},
      ]);
      expect(
        messages.any((m) => m['role'] == 'system'),
        isFalse,
        reason: 'system role must not appear in messages',
      );
    });

    test('maps HTTP 401 to MissingApiKey (Left)', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(dioErrorWithStatus(401));

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<MissingApiKey>()),
        (_) => fail('expected a Left'),
      );
    });

    test('maps HTTP 429 to RateLimited (Left)', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(dioErrorWithStatus(429));

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<RateLimited>()),
        (_) => fail('expected a Left'),
      );
    });

    test('maps a connection error to ProviderUnreachable (Left)', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/v1/messages'),
          type: DioExceptionType.connectionError,
          message: 'Connection refused',
        ),
      );

      final result = await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<ProviderUnreachable>()),
        (_) => fail('expected a Left'),
      );
    });

    test('returns MissingApiKey when the key is null without calling dio',
        () async {
      final result = await adapter.run(
        tRequest,
        apiKey: null,
        baseUrl: baseUrl,
      );

      expect(result.isLeft(), isTrue);
      result.match(
        (failure) => expect(failure, isA<MissingApiKey>()),
        (_) => fail('expected a Left'),
      );
      verifyNever(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      );
    });
  });

  group('stream', () {
    Uint8List sse(String s) => Uint8List.fromList(utf8.encode(s));

    test('concatenates content_block_delta text and emits a terminal done '
        'chunk with finishReason and usage', () async {
      final events = <Uint8List>[
        sse(
          'event: message_start\n'
          'data: {"type":"message_start",'
          '"message":{"usage":{"input_tokens":7}}}\n\n',
        ),
        sse(
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta",'
          '"delta":{"type":"text_delta","text":"Hello"}}\n\n',
        ),
        sse(
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta",'
          '"delta":{"type":"text_delta","text":", world"}}\n\n',
        ),
        sse(
          'event: message_delta\n'
          'data: {"type":"message_delta",'
          '"delta":{"stop_reason":"end_turn"},'
          '"usage":{"output_tokens":12}}\n\n',
        ),
        sse(
          'event: message_stop\n'
          'data: {"type":"message_stop"}\n\n',
        ),
      ];

      final responseBody = ResponseBody(Stream.fromIterable(events), 200);

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: responseBody,
          statusCode: 200,
          requestOptions: RequestOptions(path: '/v1/messages'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      // No Left chunks.
      expect(chunks.every((c) => c.isRight()), isTrue);

      final aiChunks = chunks
          .map((c) => c.getOrElse((_) => throw StateError('left')))
          .toList();

      // Deltas concatenate to the full text.
      final text = aiChunks.map((c) => c.delta).join();
      expect(text, 'Hello, world');

      // Terminal chunk carries done + finishReason + usage.
      final done = aiChunks.last;
      expect(done.done, isTrue);
      expect(done.delta, '');
      expect(done.finishReason, 'end_turn');
      expect(done.promptTokens, 7);
      expect(done.completionTokens, 12);

      // Exactly one terminal chunk; the two deltas precede it.
      expect(aiChunks.where((c) => c.done).length, 1);
      expect(
        aiChunks.takeWhile((c) => !c.done).map((c) => c.delta).toList(),
        const ['Hello', ', world'],
      );
    });

    test('uses a streaming responseType and includes stream:true in the body',
        () async {
      final responseBody = ResponseBody(
        Stream.fromIterable(<Uint8List>[
          sse('event: message_stop\ndata: {"type":"message_stop"}\n\n'),
        ]),
        200,
      );

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: responseBody,
          statusCode: 200,
          requestOptions: RequestOptions(path: '/v1/messages'),
        ),
      );

      await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      final captured = verify(
        mockDio.post<ResponseBody>(
          any,
          data: captureAnyNamed('data'),
          options: captureAnyNamed('options'),
        ),
      ).captured;

      final body = captured[0] as Map<String, dynamic>;
      final options = captured[1] as Options;

      expect(body['stream'], isTrue);
      expect(options.responseType, ResponseType.stream);
      expect(options.headers!['x-api-key'], apiKey);
      expect(options.headers!['anthropic-version'], '2023-06-01');
    });

    test('yields ProviderUnreachable when the response body is null', () async {
      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: null,
          statusCode: 200,
          requestOptions: RequestOptions(path: '/v1/messages'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(chunks, hasLength(1));
      chunks.single.match(
        (failure) => expect(failure, isA<ProviderUnreachable>()),
        (_) => fail('expected a Left'),
      );
    });

    test('maps a DioException during the request to a Left failure', () async {
      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(dioErrorWithStatus(429));

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(chunks, hasLength(1));
      chunks.single.match(
        (failure) => expect(failure, isA<RateLimited>()),
        (_) => fail('expected a Left'),
      );
    });

    // M1: a multibyte UTF-8 code point split across two network chunks must be
    // stitched back together by the adapter's stateful `utf8.decoder` rather
    // than corrupted to U+FFFD. We frame a `content_block_delta` whose text
    // contains an emoji (😀 = U+1F600, four UTF-8 bytes) and deliberately cut
    // the byte stream in the *middle* of that emoji's sequence so the first
    // network packet ends with an incomplete code point.
    test('reassembles a multibyte char split across two byte chunks', () async {
      const prefix = 'event: content_block_delta\n'
          'data: {"type":"content_block_delta",'
          '"delta":{"type":"text_delta","text":"café ';
      const suffix = ' done"}}\n\n'
          'event: message_stop\n'
          'data: {"type":"message_stop"}\n\n';

      final emojiBytes = utf8.encode('😀'); // 4 bytes: F0 9F 98 80.
      expect(emojiBytes, hasLength(4));

      // First packet ends two bytes into the emoji; the trailing two bytes open
      // the second packet. The decoder must carry the partial code point across.
      final firstChunk = Uint8List.fromList(
        [...utf8.encode(prefix), ...emojiBytes.sublist(0, 2)],
      );
      final secondChunk = Uint8List.fromList(
        [...emojiBytes.sublist(2), ...utf8.encode(suffix)],
      );

      final responseBody = ResponseBody(
        Stream.fromIterable(<Uint8List>[firstChunk, secondChunk]),
        200,
      );

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: responseBody,
          statusCode: 200,
          requestOptions: RequestOptions(path: '/v1/messages'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(chunks.every((c) => c.isRight()), isTrue);

      final text = chunks
          .map((c) => c.getOrElse((_) => throw StateError('left')))
          .map((c) => c.delta)
          .join();

      // The emoji (and the accented é) survive intact — no U+FFFD replacement.
      expect(text, 'café 😀 done');
      expect(text.contains('�'), isFalse);
    });

    // L10: some proxies / idle servers close the SSE stream cleanly *without*
    // ever sending `message_stop`. The adapter must still emit a synthetic
    // terminal `done` chunk carrying whatever finishReason/usage it gathered so
    // the consumer isn't left hanging without a completion signal.
    test('emits a synthetic terminal done chunk when the stream ends without '
        'message_stop', () async {
      final events = <Uint8List>[
        sse(
          'event: message_start\n'
          'data: {"type":"message_start",'
          '"message":{"usage":{"input_tokens":5}}}\n\n',
        ),
        sse(
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta",'
          '"delta":{"type":"text_delta","text":"Hi"}}\n\n',
        ),
        sse(
          'event: message_delta\n'
          'data: {"type":"message_delta",'
          '"delta":{"stop_reason":"max_tokens"},'
          '"usage":{"output_tokens":3}}\n\n',
        ),
        // Stream closes here — no `message_stop` event is ever sent.
      ];

      final responseBody = ResponseBody(Stream.fromIterable(events), 200);

      when(
        mockDio.post<ResponseBody>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<ResponseBody>(
          data: responseBody,
          statusCode: 200,
          requestOptions: RequestOptions(path: '/v1/messages'),
        ),
      );

      final chunks = await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(chunks.every((c) => c.isRight()), isTrue);

      final aiChunks = chunks
          .map((c) => c.getOrElse((_) => throw StateError('left')))
          .toList();

      // The visible delta still arrives.
      expect(
        aiChunks.takeWhile((c) => !c.done).map((c) => c.delta).join(),
        'Hi',
      );

      // Exactly one synthetic terminal chunk, carrying the gathered metadata.
      expect(aiChunks.where((c) => c.done).length, 1);
      final done = aiChunks.last;
      expect(done.done, isTrue);
      expect(done.delta, '');
      expect(done.finishReason, 'max_tokens');
      expect(done.promptTokens, 5);
      expect(done.completionTokens, 3);
    });
  });
}
