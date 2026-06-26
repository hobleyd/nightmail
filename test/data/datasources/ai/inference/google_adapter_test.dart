import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/ai/inference/google_adapter.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_request.dart';
import 'package:nightmail/domain/entities/ai/ai_response.dart';

import 'google_adapter_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GoogleAdapter adapter;

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
    adapter = GoogleAdapter(dio: mockDio);
  });

  const baseUrl = 'https://generativelanguage.googleapis.com/v1beta';
  const apiKey = 'AIza-test-key';

  final tRequest = AiRequest(
    providerId: 'google',
    modelId: 'gemini-1.5-flash',
    maxTokens: 256,
    temperature: 0.5,
    messages: const [
      AiMessage(role: AiRole.system, content: 'You are helpful.'),
      AiMessage(role: AiRole.assistant, content: 'Hi, how can I help?'),
      AiMessage(role: AiRole.user, content: 'Hello there.'),
    ],
  );

  DioException dioErrorWithStatus(int status) => DioException(
        requestOptions: RequestOptions(path: '/models'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/models'),
          statusCode: status,
        ),
        type: DioExceptionType.badResponse,
      );

  group('run', () {
    test('parses a Gemini generateContent response into an AiResponse',
        () async {
      final responseJson = {
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {'text': 'Hello, '},
                {'text': 'world'},
              ],
            },
            'finishReason': 'STOP',
          },
        ],
        'usageMetadata': {
          'promptTokenCount': 11,
          'candidatesTokenCount': 7,
        },
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
          requestOptions: RequestOptions(path: '/models'),
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
            finishReason: 'STOP',
          ),
        ),
      );
    });

    test('sends the x-goog-api-key header, builds systemInstruction from the '
        'system message, and maps assistant -> model in contents', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: const {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'},
                  ],
                },
              },
            ],
          },
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
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

      // Native generateContent endpoint with the model id baked into the path.
      expect(path, '$baseUrl/models/gemini-1.5-flash:generateContent');

      // Auth header.
      expect(options.headers!['x-goog-api-key'], apiKey);

      // System message hoisted into systemInstruction.
      final systemInstruction =
          body['systemInstruction'] as Map<String, dynamic>;
      final systemParts = (systemInstruction['parts'] as List)
          .cast<Map<String, dynamic>>();
      expect(systemParts.single['text'], 'You are helpful.');

      // contents carry only user/assistant turns; assistant -> model.
      final contents = (body['contents'] as List).cast<Map<String, dynamic>>();
      expect(contents, [
        {
          'role': 'model',
          'parts': [
            {'text': 'Hi, how can I help?'},
          ],
        },
        {
          'role': 'user',
          'parts': [
            {'text': 'Hello there.'},
          ],
        },
      ]);
      expect(
        contents.any((c) => c['role'] == 'system' || c['role'] == 'assistant'),
        isFalse,
        reason: 'system/assistant roles must not appear in contents',
      );

      // generationConfig carries temperature + maxOutputTokens.
      final generationConfig =
          body['generationConfig'] as Map<String, dynamic>;
      expect(generationConfig['temperature'], 0.5);
      expect(generationConfig['maxOutputTokens'], 256);
    });

    test('strips a stale trailing /openai from the base URL', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: const {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'},
                  ],
                },
              },
            ],
          },
          statusCode: 200,
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      await adapter.run(
        tRequest,
        apiKey: apiKey,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/',
      );

      final captured = verify(
        mockDio.post<dynamic>(
          captureAny,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).captured;

      expect(
        captured.single,
        'https://generativelanguage.googleapis.com/v1beta'
        '/models/gemini-1.5-flash:generateContent',
      );
    });

    test('maps HTTP 400 to MissingApiKey (Left)', () async {
      when(
        mockDio.post<dynamic>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(dioErrorWithStatus(400));

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
          requestOptions: RequestOptions(path: '/models'),
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
  });

  group('stream', () {
    Uint8List sse(String s) => Uint8List.fromList(utf8.encode(s));

    test('concatenates candidate part text and emits exactly one terminal done '
        'chunk with finishReason and usage', () async {
      final events = <Uint8List>[
        sse(
          'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}\n\n',
        ),
        sse(
          'data: {"candidates":[{"content":{"parts":[{"text":", world"}]}}]}'
          '\n\n',
        ),
        sse(
          'data: {"candidates":[{"content":{"parts":[{"text":"!"}]},'
          '"finishReason":"STOP"}],'
          '"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":12}}'
          '\n\n',
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
          requestOptions: RequestOptions(path: '/models'),
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
      expect(text, 'Hello, world!');

      // Exactly one terminal chunk carrying done + finishReason + usage.
      expect(aiChunks.where((c) => c.done).length, 1);
      final done = aiChunks.last;
      expect(done.done, isTrue);
      expect(done.delta, '');
      expect(done.finishReason, 'STOP');
      expect(done.promptTokens, 7);
      expect(done.completionTokens, 12);

      // The visible deltas precede the terminal chunk.
      expect(
        aiChunks.takeWhile((c) => !c.done).map((c) => c.delta).toList(),
        const ['Hello', ', world', '!'],
      );
    });

    test('uses a streaming responseType + SSE endpoint and the api-key header',
        () async {
      final responseBody = ResponseBody(
        Stream.fromIterable(<Uint8List>[
          sse(
            'data: {"candidates":[{"content":{"parts":[{"text":"hi"}]},'
            '"finishReason":"STOP"}]}\n\n',
          ),
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
          requestOptions: RequestOptions(path: '/models'),
        ),
      );

      await adapter
          .stream(tRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      final captured = verify(
        mockDio.post<ResponseBody>(
          captureAny,
          data: anyNamed('data'),
          options: captureAnyNamed('options'),
        ),
      ).captured;

      final path = captured[0] as String;
      final options = captured[1] as Options;

      expect(
        path,
        '$baseUrl/models/gemini-1.5-flash:streamGenerateContent?alt=sse',
      );
      expect(options.responseType, ResponseType.stream);
      expect(options.receiveTimeout, Duration.zero);
      expect(options.headers!['x-goog-api-key'], apiKey);
      expect(options.headers!['accept'], 'text/event-stream');
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
          requestOptions: RequestOptions(path: '/models'),
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
  });
}
