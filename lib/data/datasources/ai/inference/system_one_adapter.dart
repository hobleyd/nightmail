import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';
import '../../../../domain/entities/ai/ai_chunk.dart';
import '../../../../domain/entities/ai/ai_decision.dart';
import '../../../../domain/entities/ai/ai_provider.dart';
import '../../../../domain/entities/ai/ai_request.dart';
import '../../../../domain/entities/ai/ai_response.dart';
import 'ai_adapter.dart';

/// Wire adapter for the System One typed-decision API (TypeSafe's Jev).
///
/// `POST {base}/systemone` with `Authorization: Bearer <key>` and a body of
/// `{model, state, questions}`; the reply is `{model, answers, usage}` where
/// each answer carries `type` plus `noul` (P(true)), `choice` +
/// `probabilities`, or `score` + `legend` + `probabilities`, and a
/// `confidence`. The same shape is served by the hosted API
/// (`https://api.typesafe.ai/v1`), by the Jev-compatible local servers
/// (local-jev, jevlocal, OpenJev) and by the Laya-MLX bridge provisioned
/// outside this repo, so one instance covers every provider on
/// [AiWireProtocol.systemOne] — credentials and the endpoint are per call.
///
/// System One models generate no text, so [run] and [stream] refuse with an
/// [UnsupportedFailure] rather than inventing a chat shape the server would
/// reject: the settings UI never offers these providers to text features.
class SystemOneAdapter extends AiAdapter {
  const SystemOneAdapter({required this._dio});

  final Dio _dio;

  @override
  AiWireProtocol get protocol => AiWireProtocol.systemOne;

  static const UnsupportedFailure _noChat = UnsupportedFailure(
    message: 'System One models answer typed questions (yes/no, choice, '
        'score); they cannot write text. Route Compose to a chat model and '
        'use this provider for Triage.',
  );

  @override
  Future<Either<Failure, AiResponse>> run(
    AiRequest request, {
    required String? apiKey,
    required String baseUrl,
  }) async =>
      const Left(_noChat);

  @override
  Stream<Either<Failure, AiChunk>> stream(
    AiRequest request, {
    required String? apiKey,
    required String baseUrl,
  }) async* {
    yield const Left(_noChat);
  }

  /// `{base}/systemone`, tolerating a trailing slash or a base URL that
  /// already names the route. [baseUrl] is expected to carry `/v1`
  /// (`AiProvider.defaultBaseUrl` normalizes that for System One providers).
  static String endpointFor(String baseUrl) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base.endsWith('/systemone') ? base : '$base/systemone';
  }

  Map<String, String> _headers(String? apiKey) {
    final hasKey = apiKey != null && apiKey.isNotEmpty;
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (hasKey) 'Authorization': 'Bearer $apiKey',
    };
  }

  // --------------------------------------------------------------------------
  // Decide
  // --------------------------------------------------------------------------

  @override
  Future<Either<Failure, AiDecisionResponse>> decide(
    AiDecisionRequest request, {
    required String? apiKey,
    required String baseUrl,
  }) async {
    if (request.questions.isEmpty) {
      return const Left(
        UnsupportedFailure(message: 'A decision request needs a question.'),
      );
    }
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        endpointFor(baseUrl),
        data: encodeRequest(request),
        options: Options(headers: _headers(apiKey)),
      );

      final data = response.data;
      if (data == null) {
        return const Left(
          ProviderUnreachable(
            message: 'Empty response from the decision provider.',
          ),
        );
      }
      return parseResponse(data);
    } on DioException catch (e) {
      return Left(_mapDioError(e));
    } catch (e) {
      // Log the raw cause; surface a fixed user-safe message.
      debugPrint('SystemOneAdapter.decide failed: $e');
      return const Left(
        ProviderUnreachable(
          message: 'The decision request failed unexpectedly.',
        ),
      );
    }
  }

  /// The Jev request body: `{model, state, questions}`. `state` is passed
  /// through as-is (string, object or array are all accepted upstream).
  static Map<String, dynamic> encodeRequest(AiDecisionRequest request) => {
        'model': request.modelId,
        'state': request.state,
        'questions': {
          for (final entry in request.questions.entries)
            entry.key: encodeQuestion(entry.value),
        },
      };

  /// One question in Jev's shape: `type`, `instructions`, and type-specific
  /// `criteria` — a `{key: description}` map for choice, an ordered list of
  /// level labels for score, and an optional `{true, false}` map for noul.
  static Map<String, dynamic> encodeQuestion(AiDecisionQuestion question) {
    switch (question.type) {
      case AiDecisionQuestionType.noul:
        final hasSides = question.trueDescription != null ||
            question.falseDescription != null;
        return {
          'type': 'noul',
          'instructions': question.instructions,
          if (hasSides)
            'criteria': {
              'true': question.trueDescription ?? 'yes',
              'false': question.falseDescription ?? 'no',
            },
        };
      case AiDecisionQuestionType.choice:
        return {
          'type': 'choice',
          'instructions': question.instructions,
          'criteria': question.options,
        };
      case AiDecisionQuestionType.score:
        return {
          'type': 'score',
          'instructions': question.instructions,
          'criteria': question.levels,
        };
    }
  }

  /// Parses a `{model, answers, usage}` body. A reply with no `answers` map
  /// is treated as a provider fault (the request was accepted but nothing
  /// was decided), not as an empty result.
  static Either<Failure, AiDecisionResponse> parseResponse(
    Map<String, dynamic> data,
  ) {
    final rawAnswers = data['answers'];
    if (rawAnswers is! Map || rawAnswers.isEmpty) {
      return const Left(
        ProviderUnreachable(
          message: 'The decision provider returned no answers.',
        ),
      );
    }

    final answers = <String, AiDecisionAnswer>{};
    for (final entry in rawAnswers.entries) {
      final value = entry.value;
      if (value is Map) answers[entry.key.toString()] = _parseAnswer(value);
    }
    if (answers.isEmpty) {
      return const Left(
        ProviderUnreachable(
          message: 'The decision provider returned answers in an unexpected '
              'shape.',
        ),
      );
    }

    int? inputTokens;
    int? outputTokens;
    final usage = data['usage'];
    if (usage is Map) {
      inputTokens = (usage['input_tokens'] as num?)?.toInt();
      outputTokens = (usage['output_tokens'] as num?)?.toInt();
    }

    final model = data['model'];
    return Right(
      AiDecisionResponse(
        model: model is String ? model : '',
        answers: answers,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
      ),
    );
  }

  static AiDecisionAnswer _parseAnswer(Map raw) {
    final choice = raw['choice'];
    return AiDecisionAnswer(
      type: _parseType(raw),
      probability: _asDouble(raw['noul']),
      choice: choice is String ? choice : null,
      score: _asDouble(raw['score']),
      probabilities: _doubleMap(raw['probabilities']),
      legend: _stringMap(raw['legend']),
      confidence: _asDouble(raw['confidence']),
    );
  }

  /// The declared `type`, falling back on which value field is present for a
  /// server that omits it.
  static AiDecisionQuestionType _parseType(Map raw) {
    switch (raw['type']) {
      case 'noul':
        return AiDecisionQuestionType.noul;
      case 'choice':
        return AiDecisionQuestionType.choice;
      case 'score':
        return AiDecisionQuestionType.score;
    }
    if (raw.containsKey('noul')) return AiDecisionQuestionType.noul;
    if (raw.containsKey('choice')) return AiDecisionQuestionType.choice;
    return AiDecisionQuestionType.score;
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static Map<String, double> _doubleMap(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.value is num)
          entry.key.toString(): (entry.value as num).toDouble(),
    };
  }

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        entry.key.toString(): entry.value.toString(),
    };
  }

  // --------------------------------------------------------------------------
  // Error normalization
  // --------------------------------------------------------------------------

  Failure _mapDioError(DioException e) {
    final status = e.response?.statusCode;

    switch (e.type) {
      case DioExceptionType.cancel:
        return const ProviderUnreachable(
          message: 'Decision request was cancelled.',
        );
      case DioExceptionType.badResponse:
        break;
      default:
        // Log the raw cause for diagnostics; surface a fixed, user-safe
        // message (never the raw `e.message`, which can leak URLs/details).
        debugPrint('SystemOneAdapter transport error: ${e.type.name}: '
            '${e.message}');
        return const ProviderUnreachable(
          message: 'Could not reach the decision provider. Check that the '
              'server is running and try again.',
        );
    }

    if (status == null) {
      debugPrint('SystemOneAdapter transport error: ${e.type.name}: '
          '${e.message}');
      return const ProviderUnreachable(
        message: 'Could not reach the decision provider. Check that the '
            'server is running and try again.',
      );
    }

    // Extract the provider's error text for classification + logging only —
    // 4xx bodies can echo request fragments, so it is never surfaced.
    final detail = _extractErrorMessage(e.response?.data);
    if (detail != null) {
      debugPrint('SystemOneAdapter provider error (HTTP $status): $detail');
    }

    if (status == 401 || status == 403) {
      return MissingApiKey(
        message: 'The decision provider rejected the API key (HTTP $status). '
            'Check it in AI settings.',
      );
    }
    if (status == 429) {
      return const RateLimited(
        message: 'The decision provider is rate limiting requests '
            '(HTTP 429). Try again shortly.',
      );
    }
    if (status == 413 ||
        ((status == 400 || status == 422) && _looksLikeContextOverflow(detail))) {
      return const ContextTooLong(
        message: 'This message is too long for the selected decision model. '
            'Shorten it and try again.',
      );
    }

    return ProviderUnreachable(
      message: 'The decision provider returned an error (HTTP $status).',
    );
  }

  static String? _extractErrorMessage(Object? data) {
    if (data == null) return null;

    Object? decoded = data;
    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.isEmpty) return null;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        return trimmed;
      }
    }

    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map) {
        final msg = error['message'];
        if (msg is String && msg.isNotEmpty) return msg;
      }
      if (error is String && error.isNotEmpty) return error;
      // FastAPI-style validation errors (`detail`) from the local servers.
      final detail = decoded['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is List && detail.isNotEmpty) return detail.toString();
      final msg = decoded['message'];
      if (msg is String && msg.isNotEmpty) return msg;
    }
    return null;
  }

  static bool _looksLikeContextOverflow(String? detail) {
    if (detail == null) return false;
    final d = detail.toLowerCase();
    return d.contains('context') ||
        d.contains('too long') ||
        d.contains('too many tokens') ||
        d.contains('token budget') ||
        (d.contains('token') && d.contains('maximum'));
  }
}
