import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/ai/inference/system_one_adapter.dart';
import 'package:nightmail/domain/entities/ai/ai_decision.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_provider.dart';
import 'package:nightmail/domain/entities/ai/ai_request.dart';

import 'system_one_adapter_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late SystemOneAdapter adapter;
  late MockDio mockDio;

  const baseUrl = 'https://api.typesafe.ai/v1';
  const apiKey = 'jv_live_test';

  // One of each question type, so encoding and parsing cover every branch.
  const tRequest = AiDecisionRequest(
    providerId: 'jev',
    modelId: 'jev-latest',
    state: {
      'subject': 'Duplicate charge',
      'body': 'Billed twice, please refund the duplicate.',
    },
    questions: {
      'department': AiDecisionQuestion.choice(
        instructions: 'Which team should handle this?',
        options: {'billing': 'Payments, refunds', 'technical': 'Bugs'},
      ),
      'urgent': AiDecisionQuestion.noul(instructions: 'Is this urgent?'),
      'frustration': AiDecisionQuestion.score(
        instructions: 'How frustrated is the sender?',
        levels: ['calm', 'annoyed', 'furious'],
      ),
    },
  );

  final tChatRequest = AiRequest(
    messages: const [AiMessage(role: AiRole.user, content: 'Hello')],
    providerId: 'jev',
    modelId: 'jev-latest',
  );

  setUp(() {
    // Mockito needs a dummy value to return from the generic `post` while a
    // `when(...)` stub is being recorded; the real value comes from thenAnswer.
    provideDummy<Response<Map<String, dynamic>>>(
      Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: ''),
      ),
    );
    mockDio = MockDio();
    adapter = SystemOneAdapter(dio: mockDio);
  });

  RequestOptions ro() => RequestOptions(path: '$baseUrl/systemone');

  void stubPost(Map<String, dynamic> body) {
    when(mockDio.post<Map<String, dynamic>>(
      any,
      data: anyNamed('data'),
      options: anyNamed('options'),
    )).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: ro(),
        statusCode: 200,
        data: body,
      ),
    );
  }

  void stubPostThrows(DioException error) {
    when(mockDio.post<Map<String, dynamic>>(
      any,
      data: anyNamed('data'),
      options: anyNamed('options'),
    )).thenThrow(error);
  }

  DioException badResponse(int status, {Object? data}) => DioException(
        requestOptions: ro(),
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(
          requestOptions: ro(),
          statusCode: status,
          data: data,
        ),
      );

  group('endpointFor', () {
    test('appends /systemone to a /v1 base, tolerating a trailing slash', () {
      expect(
        SystemOneAdapter.endpointFor('https://api.typesafe.ai/v1'),
        'https://api.typesafe.ai/v1/systemone',
      );
      expect(
        SystemOneAdapter.endpointFor('http://127.0.0.1:8766/v1/'),
        'http://127.0.0.1:8766/v1/systemone',
      );
    });

    test('does not double a base that already names the route', () {
      expect(
        SystemOneAdapter.endpointFor('http://127.0.0.1:8765/v1/systemone'),
        'http://127.0.0.1:8765/v1/systemone',
      );
    });
  });

  group('encodeRequest', () {
    test('produces the Jev {model, state, questions} body', () {
      final body = SystemOneAdapter.encodeRequest(tRequest);

      expect(body['model'], 'jev-latest');
      // State passes through untouched (string, object or array upstream).
      expect(body['state'], tRequest.state);

      final questions = body['questions'] as Map<String, dynamic>;
      expect(questions['department'], {
        'type': 'choice',
        'instructions': 'Which team should handle this?',
        'criteria': {'billing': 'Payments, refunds', 'technical': 'Bugs'},
      });
      // A plain noul carries no criteria at all.
      expect(questions['urgent'], {
        'type': 'noul',
        'instructions': 'Is this urgent?',
      });
      expect(questions['frustration'], {
        'type': 'score',
        'instructions': 'How frustrated is the sender?',
        'criteria': ['calm', 'annoyed', 'furious'],
      });
    });

    test('a noul with side descriptions emits criteria.true / criteria.false',
        () {
      final encoded = SystemOneAdapter.encodeQuestion(
        const AiDecisionQuestion.noul(
          instructions: 'Is this phishing?',
          trueDescription: 'phishing, scam or fraud',
        ),
      );
      expect(encoded['criteria'], {
        'true': 'phishing, scam or fraud',
        // The unspecified side is filled so the server sees both keys.
        'false': 'no',
      });
    });
  });

  group('decide', () {
    test('posts to {base}/systemone with a Bearer key and parses the answers',
        () async {
      stubPost({
        'model': 'jev-1.13.0',
        'answers': {
          'department': {
            'type': 'choice',
            'choice': 'billing',
            'probabilities': {'billing': 0.85, 'technical': 0.15},
            'confidence': 0.82,
          },
          'urgent': {'type': 'noul', 'noul': 0.82},
          'frustration': {
            'type': 'score',
            'score': 1.2,
            'legend': {'0': 'calm', '1': 'annoyed', '2': 'furious'},
            'probabilities': {'0': 0.1, '1': 0.6, '2': 0.3},
            'confidence': 0.6,
          },
        },
        'usage': {'input_tokens': 312, 'output_tokens': 48},
      });

      final result = await adapter.decide(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      final captured = verify(mockDio.post<Map<String, dynamic>>(
        captureAny,
        data: captureAnyNamed('data'),
        options: captureAnyNamed('options'),
      )).captured;
      expect(captured[0], 'https://api.typesafe.ai/v1/systemone');
      expect((captured[1] as Map)['model'], 'jev-latest');
      final headers = (captured[2] as Options).headers!;
      expect(headers['Authorization'], 'Bearer $apiKey');
      expect(headers['Content-Type'], 'application/json');

      final response = result.getOrElse((f) => fail('expected Right, got $f'));
      expect(response.model, 'jev-1.13.0');
      expect(response.inputTokens, 312);
      expect(response.outputTokens, 48);

      final department = response.answers['department']!;
      expect(department.type, AiDecisionQuestionType.choice);
      expect(department.choice, 'billing');
      expect(department.probabilities['billing'], 0.85);
      expect(department.confidence, 0.82);
      expect(department.summary, 'billing 85%');

      final urgent = response.answers['urgent']!;
      expect(urgent.type, AiDecisionQuestionType.noul);
      expect(urgent.probability, 0.82);
      expect(urgent.summary, 'yes 82%');

      final frustration = response.answers['frustration']!;
      expect(frustration.type, AiDecisionQuestionType.score);
      expect(frustration.score, 1.2);
      expect(frustration.scoreLabel, 'annoyed');
      expect(frustration.summary, 'annoyed (1.2)');
    });

    test('sends no Authorization header when no key is stored (local bridge)',
        () async {
      stubPost({
        'model': 'aac6fef/laya-mlx',
        'answers': {
          'urgent': {'type': 'noul', 'noul': 0.3, 'confidence': 0.7},
        },
      });

      final result = await adapter.decide(
        tRequest,
        apiKey: null,
        baseUrl: 'http://127.0.0.1:8766/v1',
      );

      final captured = verify(mockDio.post<Map<String, dynamic>>(
        captureAny,
        data: anyNamed('data'),
        options: captureAnyNamed('options'),
      )).captured;
      expect(captured[0], 'http://127.0.0.1:8766/v1/systemone');
      expect(
        (captured[1] as Options).headers!.containsKey('Authorization'),
        isFalse,
      );
      expect(result.isRight(), isTrue);
      // A `no` answer summarises with the complementary probability.
      expect(
        result.getOrElse((_) => fail('expected Right')).answers['urgent']!.summary,
        'no 70%',
      );
    });

    test('infers the answer type from its value field when `type` is absent',
        () async {
      stubPost({
        'answers': {
          'a': {'noul': 0.9},
          'b': {'choice': 'x', 'probabilities': {'x': 1.0}},
          'c': {'score': 0.0, 'legend': {'0': 'none'}},
        },
      });

      final response = (await adapter.decide(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      ))
          .getOrElse((_) => fail('expected Right'));

      expect(response.answers['a']!.type, AiDecisionQuestionType.noul);
      expect(response.answers['b']!.type, AiDecisionQuestionType.choice);
      expect(response.answers['c']!.type, AiDecisionQuestionType.score);
      // No `model` in the body → empty string, never null.
      expect(response.model, '');
    });

    test('a reply with no answers is a ProviderUnreachable', () async {
      stubPost({'model': 'jev-1.13.0', 'answers': <String, dynamic>{}});

      final result = await adapter.decide(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      result.match(
        (f) => expect(f, isA<ProviderUnreachable>()),
        (_) => fail('expected Left'),
      );
    });

    test('maps HTTP 401 to MissingApiKey', () async {
      stubPostThrows(badResponse(401, data: {
        'error': {'message': 'invalid api key'},
      }));

      final result = await adapter.decide(
        tRequest,
        apiKey: 'bad',
        baseUrl: baseUrl,
      );

      result.match(
        (f) => expect(f, isA<MissingApiKey>()),
        (_) => fail('expected Left'),
      );
    });

    test('maps HTTP 429 to RateLimited', () async {
      stubPostThrows(badResponse(429));

      final result = await adapter.decide(
        tRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      result.match(
        (f) => expect(f, isA<RateLimited>()),
        (_) => fail('expected Left'),
      );
    });

    test('maps a 422 token-budget rejection to ContextTooLong', () async {
      // The shape the Laya-MLX bridge / local-jev return when a question has
      // too many options for the model's token budget.
      stubPostThrows(badResponse(422, data: {
        'error': {
          'message': "Question 'category' has too many options for the "
              'token budget',
          'type': 'invalid_request',
        },
      }));

      final result = await adapter.decide(
        tRequest,
        apiKey: null,
        baseUrl: 'http://127.0.0.1:8766/v1',
      );

      result.match(
        (f) => expect(f, isA<ContextTooLong>()),
        (_) => fail('expected Left'),
      );
    });

    test('maps a connection error to ProviderUnreachable', () async {
      stubPostThrows(DioException(
        requestOptions: ro(),
        type: DioExceptionType.connectionError,
        message: 'Connection refused',
      ));

      final result = await adapter.decide(
        tRequest,
        apiKey: null,
        baseUrl: 'http://127.0.0.1:8766/v1',
      );

      result.match(
        (f) {
          expect(f, isA<ProviderUnreachable>());
          // The raw transport message (which can carry the URL) is not
          // surfaced; the user gets a fixed hint instead.
          expect(f.message, isNot(contains('refused')));
          expect(f.message, contains('server is running'));
        },
        (_) => fail('expected Left'),
      );
    });

    test('refuses an empty question set without a network call', () async {
      const empty = AiDecisionRequest(
        providerId: 'jev',
        modelId: 'jev-latest',
        state: 'hello',
        questions: {},
      );

      final result = await adapter.decide(
        empty,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      result.match(
        (f) => expect(f, isA<UnsupportedFailure>()),
        (_) => fail('expected Left'),
      );
      verifyNever(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      ));
    });
  });

  group('chat operations', () {
    test('protocol is systemOne', () {
      expect(adapter.protocol, AiWireProtocol.systemOne);
    });

    test('run refuses with UnsupportedFailure and makes no network call',
        () async {
      final result = await adapter.run(
        tChatRequest,
        apiKey: apiKey,
        baseUrl: baseUrl,
      );

      result.match(
        (f) => expect(f, isA<UnsupportedFailure>()),
        (_) => fail('expected Left'),
      );
      verifyZeroInteractions(mockDio);
    });

    test('stream yields a single UnsupportedFailure', () async {
      final events = await adapter
          .stream(tChatRequest, apiKey: apiKey, baseUrl: baseUrl)
          .toList();

      expect(events, hasLength(1));
      events.single.match(
        (f) => expect(f, isA<UnsupportedFailure>()),
        (_) => fail('expected Left'),
      );
      verifyZeroInteractions(mockDio);
    });
  });
}
