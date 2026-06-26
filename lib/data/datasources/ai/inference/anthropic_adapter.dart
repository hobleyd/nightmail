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

/// [AiAdapter] for providers speaking Anthropic's Messages API
/// (`AiWireProtocol.anthropic`).
///
/// Maps an [AiRequest] onto `POST {baseUrl}/v1/messages` with the `x-api-key`
/// and `anthropic-version` headers. Unlike the OpenAI chat schema, the system
/// prompt is hoisted into the top-level `system` field and the `messages` array
/// carries only `user` / `assistant` turns. The streaming path consumes
/// Anthropic's SSE events (`message_start`, `content_block_delta`,
/// `message_delta`, `message_stop`) over a `dio` byte stream.
///
/// A single instance serves every Anthropic-protocol provider — the API key and
/// endpoint are supplied per call (see [AiAdapter]).
class AnthropicAdapter implements AiAdapter {
  const AnthropicAdapter({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// Default endpoint for the first-party Anthropic API.
  static const String _defaultBaseUrl = 'https://api.anthropic.com';

  /// Pinned Messages API version (sent as the `anthropic-version` header).
  static const String _anthropicVersion = '2023-06-01';

  /// Anthropic requires `max_tokens`; used when [AiRequest.maxTokens] is null.
  static const int _defaultMaxTokens = 4096;

  @override
  AiWireProtocol get protocol => AiWireProtocol.anthropic;

  @override
  Future<Either<Failure, AiResponse>> run(
    AiRequest request, {
    required String? apiKey,
    required String baseUrl,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      return const Left(
        MissingApiKey(message: 'Anthropic requires an API key.'),
      );
    }

    try {
      final response = await _dio.post<dynamic>(
        _endpoint(baseUrl),
        data: _buildBody(request, stream: false),
        options: Options(headers: _headers(apiKey, stream: false)),
      );

      final data = response.data;
      if (data is! Map) {
        return const Left(
          ProviderUnreachable(
            message: 'Anthropic returned an unexpected response shape.',
          ),
        );
      }

      final text = _extractText(data['content']);
      final (promptTokens, completionTokens) = _extractUsage(data['usage']);
      final finishReason =
          data['stop_reason'] is String ? data['stop_reason'] as String : null;

      return Right(
        AiResponse(
          text: text,
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          finishReason: finishReason,
        ),
      );
    } on DioException catch (e) {
      return Left(_failureFromDio(e));
    } catch (e) {
      // L12: never echo the raw exception into a user-facing message (it may
      // carry transport internals). Log it for debugging; surface a fixed
      // user-safe message.
      debugPrint('AnthropicAdapter.run failed: $e');
      return const Left(
        ProviderUnreachable(message: 'Anthropic request failed.'),
      );
    }
  }

  @override
  Stream<Either<Failure, AiChunk>> stream(
    AiRequest request, {
    required String? apiKey,
    required String baseUrl,
  }) async* {
    if (apiKey == null || apiKey.isEmpty) {
      yield const Left(
        MissingApiKey(message: 'Anthropic requires an API key.'),
      );
      return;
    }

    Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        _endpoint(baseUrl),
        data: _buildBody(request, stream: true),
        options: Options(
          headers: _headers(apiKey, stream: true),
          responseType: ResponseType.stream,
          // Contract #8: token streams can run far longer than the shared
          // Dio `receiveTimeout` (60s). Disable the per-call receive timeout
          // so a long generation isn't cut off mid-stream.
          receiveTimeout: Duration.zero,
        ),
      );
    } on DioException catch (e) {
      yield Left(_failureFromDio(e));
      return;
    } catch (e) {
      // L12: log the raw cause; surface a fixed user-safe message.
      debugPrint('AnthropicAdapter.stream request failed: $e');
      yield const Left(
        ProviderUnreachable(message: 'Anthropic stream failed.'),
      );
      return;
    }

    final body = response.data;
    if (body == null) {
      yield const Left(
        ProviderUnreachable(message: 'Anthropic returned an empty stream.'),
      );
      return;
    }

    int? promptTokens;
    int? completionTokens;
    String? finishReason;
    var terminated = false;

    // M1: decode the byte stream with a single stateful `utf8.decoder` (as the
    // OpenAI adapter does) so multibyte code points split across dio/TCP chunk
    // boundaries carry over instead of being corrupted to U+FFFD. `LineSplitter`
    // then yields whole SSE lines regardless of how bytes were framed.
    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    try {
      await for (final raw in lines) {
        final line = raw.trim();
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;

        Map<String, dynamic> event;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic>) continue;
          event = decoded;
        } catch (_) {
          continue;
        }

        final type = event['type'];
        if (type == 'message_start') {
          final usage = event['message'] is Map
              ? (event['message'] as Map)['usage']
              : null;
          final (p, _) = _extractUsage(usage);
          promptTokens = p ?? promptTokens;
        } else if (type == 'content_block_delta') {
          final delta = event['delta'];
          if (delta is Map && delta['text'] is String) {
            yield Right(AiChunk(delta: delta['text'] as String));
          }
        } else if (type == 'message_delta') {
          final delta = event['delta'];
          if (delta is Map && delta['stop_reason'] is String) {
            finishReason = delta['stop_reason'] as String;
          }
          final (_, c) = _extractUsage(event['usage']);
          completionTokens = c ?? completionTokens;
        } else if (type == 'message_stop') {
          terminated = true;
          yield Right(
            AiChunk(
              delta: '',
              done: true,
              finishReason: finishReason,
              promptTokens: promptTokens,
              completionTokens: completionTokens,
            ),
          );
        } else if (type == 'error') {
          yield Left(_failureFromErrorEvent(event['error']));
          return;
        }
        // `ping`, `content_block_start`, and `content_block_stop` carry no
        // user-visible payload and are ignored.
      }
    } on DioException catch (e) {
      yield Left(_failureFromDio(e));
      return;
    } catch (e) {
      // L12: log the raw cause; surface a fixed user-safe message.
      debugPrint('AnthropicAdapter.stream interrupted: $e');
      yield const Left(
        ProviderUnreachable(message: 'Anthropic stream interrupted.'),
      );
      return;
    }

    // L10: some proxies/idle servers close the stream cleanly without sending
    // `message_stop`. Emit a synthetic terminal chunk so the consumer still
    // receives `done` with whatever finishReason/usage was gathered.
    if (!terminated) {
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
  }

  /// Resolves the Messages endpoint, defaulting to the first-party API when no
  /// [baseUrl] is supplied and stripping any trailing slashes.
  String _endpoint(String baseUrl) {
    final trimmed = baseUrl.trim();
    final base = (trimmed.isEmpty ? _defaultBaseUrl : trimmed)
        .replaceAll(RegExp(r'/+$'), '');
    return '$base/v1/messages';
  }

  Map<String, String> _headers(String apiKey, {required bool stream}) => {
        'x-api-key': apiKey,
        'anthropic-version': _anthropicVersion,
        'content-type': 'application/json',
        'accept': stream ? 'text/event-stream' : 'application/json',
      };

  /// Maps an [AiRequest] onto the Anthropic Messages wire body: the system
  /// prompt is hoisted to the top-level `system` field; only user/assistant
  /// turns remain in `messages`.
  Map<String, dynamic> _buildBody(AiRequest request, {required bool stream}) {
    String? system;
    final messages = <Map<String, dynamic>>[];

    for (final message in request.messages) {
      switch (message.role) {
        case AiRole.system:
          system =
              system == null ? message.content : '$system\n\n${message.content}';
        case AiRole.user:
          messages.add({'role': 'user', 'content': message.content});
        case AiRole.assistant:
          messages.add({'role': 'assistant', 'content': message.content});
      }
    }

    return {
      'model': request.modelId,
      'max_tokens': request.maxTokens ?? _defaultMaxTokens,
      'messages': messages,
      'system': ?system,
      'temperature': ?request.temperature,
      if (stream) 'stream': true,
    };
  }

  /// Concatenates the text of every `text` content block in a Messages
  /// response.
  String _extractText(dynamic content) {
    if (content is! List) return '';
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is Map && block['type'] == 'text' && block['text'] is String) {
        buffer.write(block['text'] as String);
      }
    }
    return buffer.toString();
  }

  /// Reads `input_tokens` / `output_tokens` from an Anthropic `usage` object.
  (int?, int?) _extractUsage(dynamic usage) {
    if (usage is! Map) return (null, null);
    final input = (usage['input_tokens'] as num?)?.toInt();
    final output = (usage['output_tokens'] as num?)?.toInt();
    return (input, output);
  }

  /// Normalizes a transport-level [DioException] into an [AiFailure].
  Failure _failureFromDio(DioException e) {
    final status = e.response?.statusCode;

    if (status == 429) {
      return RateLimited(
        message: _extractMessage(e) ?? 'Anthropic rate limit exceeded.',
      );
    }
    if (status == 401 || status == 403) {
      return MissingApiKey(
        message: _extractMessage(e) ?? 'Anthropic rejected the API key.',
      );
    }
    if (status == 400) {
      final message = _extractMessage(e);
      final lower = (message ?? '').toLowerCase();
      if (lower.contains('prompt is too long') ||
          lower.contains('context') ||
          lower.contains('max_tokens')) {
        return ContextTooLong(
          message: message ?? 'Request exceeds the model context window.',
        );
      }
      return ServerFailure(
        message: message ?? 'Anthropic rejected the request.',
        statusCode: 400,
      );
    }
    if (status != null) {
      return ServerFailure(
        message: _extractMessage(e) ?? 'Anthropic request failed.',
        statusCode: status,
      );
    }

    // No HTTP response → connection/timeout failure. L12: log the raw transport
    // detail rather than interpolating it into the user-facing message.
    debugPrint('AnthropicAdapter transport error: ${e.message ?? e.type.name}');
    return const ProviderUnreachable(
      message: 'Could not reach Anthropic.',
    );
  }

  /// Maps an Anthropic SSE `error` event payload onto an [AiFailure].
  Failure _failureFromErrorEvent(dynamic error) {
    var type = '';
    var message = 'Anthropic stream error.';
    if (error is Map) {
      if (error['type'] is String) type = error['type'] as String;
      if (error['message'] is String) message = error['message'] as String;
    }
    if (type.contains('rate_limit') || type.contains('overloaded')) {
      return RateLimited(message: message);
    }
    return ServerFailure(message: message);
  }

  /// Extracts a human-readable message from an Anthropic error body
  /// (`{type: error, error: {type, message}}`).
  String? _extractMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map) {
      final error = data['error'];
      if (error is Map && error['message'] is String) {
        return error['message'] as String;
      }
      if (data['message'] is String) return data['message'] as String;
    }
    if (data is String && data.isNotEmpty) return data;
    return null;
  }
}
