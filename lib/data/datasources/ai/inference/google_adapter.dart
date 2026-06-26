import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';
import '../../../../domain/entities/ai/ai_chunk.dart';
import '../../../../domain/entities/ai/ai_message.dart';
import '../../../../domain/entities/ai/ai_provider.dart';
import '../../../../domain/entities/ai/ai_request.dart';
import '../../../../domain/entities/ai/ai_response.dart';
import 'ai_adapter.dart';

/// [AiAdapter] for providers speaking Google's native Gemini
/// `generateContent` API (`AiWireProtocol.google`).
///
/// Unlike the OpenAI-compatible surface (`.../v1beta/openai`), this hits the
/// native Gemini REST endpoints: `POST {base}/models/{modelId}:generateContent`
/// for single-shot and `POST {base}/models/{modelId}:streamGenerateContent?alt=sse`
/// for streaming. The key is carried in the `x-goog-api-key` header.
///
/// The Gemini body differs from the OpenAI chat schema: turns live under
/// `contents` as `{role, parts:[{text}]}` (with the assistant role spelled
/// `model`), the system prompt is hoisted into a top-level `systemInstruction`,
/// and sampling controls live under `generationConfig`. The streaming path
/// consumes Gemini's SSE `data: {json}` events, each carrying incremental
/// `candidates[].content.parts[].text`.
///
/// A single instance serves every Google-protocol provider — the API key and
/// endpoint are supplied per call (see [AiAdapter]).
class GoogleAdapter implements AiAdapter {
  GoogleAdapter({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// Default endpoint for the first-party Gemini API (native surface).
  static const String _defaultBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  @override
  AiWireProtocol get protocol => AiWireProtocol.google;

  @override
  Future<Either<Failure, AiResponse>> run(
    AiRequest request, {
    required String? apiKey,
    required String baseUrl,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        _endpoint(baseUrl, request.modelId, stream: false),
        data: _buildBody(request),
        options: Options(headers: _headers(apiKey, stream: false)),
      );

      final data = response.data;
      if (data is! Map) {
        return const Left(
          ProviderUnreachable(
            message: 'Gemini returned an unexpected response shape.',
          ),
        );
      }

      final candidates = data['candidates'];
      final candidate = (candidates is List && candidates.isNotEmpty)
          ? candidates.first
          : null;

      final text = _extractText(candidate);
      final finishReason =
          (candidate is Map && candidate['finishReason'] is String)
              ? candidate['finishReason'] as String
              : null;
      final (promptTokens, completionTokens) =
          _extractUsage(data['usageMetadata']);

      return Right(
        AiResponse(
          text: text,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          finishReason: finishReason,
        ),
      );
    } on DioException catch (e) {
      return Left(_mapDioError(e));
    } catch (e) {
      // L12: never echo the raw exception into a user-facing message (it may
      // carry transport internals). Log it for debugging; surface a fixed
      // user-safe message.
      debugPrint('GoogleAdapter.run failed: $e');
      return const Left(
        ProviderUnreachable(message: 'Gemini request failed.'),
      );
    }
  }

  @override
  Stream<Either<Failure, AiChunk>> stream(
    AiRequest request, {
    required String? apiKey,
    required String baseUrl,
  }) async* {
    Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        _endpoint(baseUrl, request.modelId, stream: true),
        data: _buildBody(request),
        options: Options(
          headers: _headers(apiKey, stream: true),
          responseType: ResponseType.stream,
          // Contract #8: token streams can run far longer than the shared Dio
          // `receiveTimeout` (60s). Disable the per-call receive timeout so a
          // long generation isn't cut off mid-stream.
          receiveTimeout: Duration.zero,
        ),
      );
    } on DioException catch (e) {
      yield Left(_mapDioError(e));
      return;
    } catch (e) {
      // L12: log the raw cause; surface a fixed user-safe message.
      debugPrint('GoogleAdapter.stream request failed: $e');
      yield const Left(
        ProviderUnreachable(message: 'Gemini stream failed.'),
      );
      return;
    }

    final body = response.data;
    if (body == null) {
      yield const Left(
        ProviderUnreachable(message: 'Gemini returned an empty stream.'),
      );
      return;
    }

    int? promptTokens;
    int? completionTokens;
    String? finishReason;

    // Decode the byte stream with a single stateful `utf8.decoder` (as the
    // OpenAI/Anthropic adapters do) so multibyte code points split across
    // dio/TCP chunk boundaries carry over instead of being corrupted to
    // U+FFFD. `LineSplitter` then yields whole SSE lines regardless of how
    // bytes were framed.
    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    try {
      await for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty || !line.startsWith('data:')) continue;

        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;

        Map<String, dynamic> json;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic>) continue;
          json = decoded;
        } catch (_) {
          // Skip keep-alive / non-JSON SSE comment lines.
          continue;
        }

        final candidates = json['candidates'];
        final candidate = (candidates is List && candidates.isNotEmpty)
            ? candidates.first
            : null;

        if (candidate is Map) {
          final text = _extractText(candidate);
          if (text.isNotEmpty) {
            yield Right(AiChunk(delta: text));
          }
          if (candidate['finishReason'] is String) {
            finishReason = candidate['finishReason'] as String;
          }
        }

        final (p, c) = _extractUsage(json['usageMetadata']);
        promptTokens = p ?? promptTokens;
        completionTokens = c ?? completionTokens;
      }
    } on DioException catch (e) {
      yield Left(_mapDioError(e));
      return;
    } catch (e) {
      // L12: log the raw cause; surface a fixed user-safe message.
      debugPrint('GoogleAdapter.stream interrupted: $e');
      yield const Left(
        ProviderUnreachable(message: 'Gemini stream interrupted.'),
      );
      return;
    }

    // Gemini's SSE stream has no explicit terminal sentinel: it simply ends
    // after the chunk carrying the final `finishReason`/usage. Emit one
    // synthetic terminal chunk carrying whatever finishReason/usage was
    // gathered so the consumer always receives a `done` signal.
    yield Right(
      AiChunk(
        delta: '',
        done: true,
        finishReason: finishReason,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
      ),
    );
  }

  /// Resolves the Gemini endpoint for [modelId], defaulting to the first-party
  /// API when no [baseUrl] is supplied.
  ///
  /// Strips a trailing slash, and a trailing `/openai` (a stale
  /// OpenAI-compatible base) so we always hit the native `generateContent`
  /// surface.
  String _endpoint(String baseUrl, String modelId, {required bool stream}) {
    final trimmed = baseUrl.trim();
    var base = (trimmed.isEmpty ? _defaultBaseUrl : trimmed)
        .replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/openai')) {
      base = base.substring(0, base.length - '/openai'.length);
    }
    final method = stream ? 'streamGenerateContent?alt=sse' : 'generateContent';
    return '$base/models/$modelId:$method';
  }

  Map<String, String> _headers(String? apiKey, {required bool stream}) {
    final hasKey = apiKey != null && apiKey.isNotEmpty;
    return {
      'content-type': 'application/json',
      'accept': stream ? 'text/event-stream' : 'application/json',
      if (hasKey) 'x-goog-api-key': apiKey,
    };
  }

  /// Maps an [AiRequest] onto the native Gemini `generateContent` body: the
  /// system prompt is hoisted into `systemInstruction`; user/assistant turns
  /// become `contents` (with `assistant` spelled `model`); sampling controls
  /// live under `generationConfig`.
  Map<String, dynamic> _buildBody(AiRequest request) {
    final contents = <Map<String, dynamic>>[];
    final systemParts = <String>[];

    for (final message in request.messages) {
      switch (message.role) {
        case AiRole.system:
          systemParts.add(message.content);
        case AiRole.user:
          contents.add({
            'role': 'user',
            'parts': [
              {'text': message.content},
            ],
          });
        case AiRole.assistant:
          // Gemini spells the assistant role `model`.
          contents.add({
            'role': 'model',
            'parts': [
              {'text': message.content},
            ],
          });
      }
    }

    final body = <String, dynamic>{'contents': contents};

    if (systemParts.isNotEmpty) {
      body['systemInstruction'] = {
        'parts': [
          {'text': systemParts.join('\n\n')},
        ],
      };
    }

    final generationConfig = <String, dynamic>{
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxTokens != null) 'maxOutputTokens': request.maxTokens,
    };
    if (generationConfig.isNotEmpty) {
      body['generationConfig'] = generationConfig;
    }

    return body;
  }

  /// Concatenates the text of every `parts[].text` in a Gemini candidate's
  /// `content`.
  String _extractText(dynamic candidate) {
    if (candidate is! Map) return '';
    final content = candidate['content'];
    if (content is! Map) return '';
    final parts = content['parts'];
    if (parts is! List) return '';
    final buffer = StringBuffer();
    for (final part in parts) {
      if (part is Map && part['text'] is String) {
        buffer.write(part['text'] as String);
      }
    }
    return buffer.toString();
  }

  /// Reads `promptTokenCount` / `candidatesTokenCount` from a Gemini
  /// `usageMetadata` object.
  (int?, int?) _extractUsage(dynamic usage) {
    if (usage is! Map) return (null, null);
    final prompt = (usage['promptTokenCount'] as num?)?.toInt();
    final completion = (usage['candidatesTokenCount'] as num?)?.toInt();
    return (prompt, completion);
  }

  /// Normalizes a transport-level [DioException] into an [AiFailure].
  ///
  /// Gemini returns 400 ("API key not valid") or 403 for bad keys, 429 for
  /// rate limits. Its error body is `{"error":{"code":..,"message":..,
  /// "status":..}}` — extracted only for diagnostics/classification, never
  /// surfaced verbatim (L12).
  Failure _mapDioError(DioException e) {
    final status = e.response?.statusCode;

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
        // L12: log the raw cause for diagnostics; surface a fixed, user-safe
        // message (never the raw `e.message`, which can leak URLs/details).
        debugPrint('GoogleAdapter transport error: ${e.type.name}: '
            '${e.message}');
        return const ProviderUnreachable(
          message: 'Could not reach Gemini. '
              'Check your connection and try again.',
        );
      case DioExceptionType.cancel:
        return const ProviderUnreachable(message: 'Gemini request was cancelled.');
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        break;
    }

    if (status == null) {
      debugPrint('GoogleAdapter transport error: ${e.type.name}: '
          '${e.message}');
      return const ProviderUnreachable(
        message: 'Could not reach Gemini. '
            'Check your connection and try again.',
      );
    }

    // L12: extract the provider's error text for diagnostics only — never
    // surface it verbatim, since 4xx bodies can echo request fragments.
    final detail = _extractErrorMessage(e.response?.data);
    if (detail != null) {
      debugPrint('GoogleAdapter provider error (HTTP $status): $detail');
    }

    if (status == 429) {
      return const RateLimited(
        message: 'Gemini is rate limiting requests (HTTP 429). '
            'Try again shortly.',
      );
    }
    if (status == 400 || status == 401 || status == 403) {
      // Gemini reports an invalid/missing key as 400 ("API key not valid") or
      // 403; treat the 400 here as a key problem for parity with siblings.
      return MissingApiKey(
        message: 'Gemini rejected the API key (HTTP $status). '
            'Check it in AI settings.',
      );
    }

    return ProviderUnreachable(
      message: 'Gemini returned an error (HTTP $status).',
    );
  }

  /// Best-effort extraction of a human message from a Gemini error body
  /// (`{error: {message}}`), used only for diagnostic logging — never surfaced
  /// to the user verbatim (see [_mapDioError]). Tolerates a parsed Map, a raw
  /// JSON string, or absent body.
  String? _extractErrorMessage(Object? data) {
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
      if (error is Map && error['message'] is String) {
        return error['message'] as String;
      }
      if (error is String && error.isNotEmpty) return error;
      if (decoded['message'] is String) return decoded['message'] as String;
    }
    return null;
  }
}
