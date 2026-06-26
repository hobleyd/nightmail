import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';

/// Lists the model ids a live OpenAI-compatible endpoint advertises at its
/// `/models` route.
///
/// Used for BYO / self-hosted servers (Ollama, LM Studio, vLLM, a proxy…) that
/// are not in the static models.dev catalog, so the settings UI can offer a real
/// model dropdown instead of a free-text box.
abstract interface class ProviderModelsDatasource {
  /// Model ids reported by a provider's endpoint.
  ///
  /// For OpenAI-compatible servers: `GET {baseUrl}/models` with a Bearer key.
  /// For [azure]: `GET {resource}/openai/deployments?api-version=…` with the
  /// `api-key` header — i.e. the user's *deployments* (whose `id` is the value
  /// to pass as `model`), not Azure's full model catalog.
  Future<List<String>> list({
    required String baseUrl,
    String? apiKey,
    bool azure = false,
  });
}

class ProviderModelsDatasourceImpl implements ProviderModelsDatasource {
  ProviderModelsDatasourceImpl({required Dio dio}) : _dio = dio;

  final Dio _dio;

  @override
  Future<List<String>> list({
    required String baseUrl,
    String? apiKey,
    bool azure = false,
  }) async {
    final base = baseUrl.trim();
    final hasKey = apiKey != null && apiKey.isNotEmpty;

    late final String url;
    late final Map<String, dynamic>? query;
    late final Map<String, String> headers;

    if (azure) {
      // Azure: list deployments off the resource root (strip the `/openai/v1`
      // suffix), authenticated with the `api-key` header.
      final uri = Uri.parse(base);
      final root = '${uri.scheme}://${uri.host}';
      url = '$root/openai/deployments';
      query = const {'api-version': '2023-03-15-preview'};
      headers = {if (hasKey) 'api-key': apiKey};
    } else {
      final normalized =
          base.endsWith('/') ? base.substring(0, base.length - 1) : base;
      url = '$normalized/models';
      query = null;
      headers = {if (hasKey) 'Authorization': 'Bearer $apiKey'};
    }

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        url,
        queryParameters: query,
        options: Options(headers: headers),
      );

      // Both shapes: { "data": [ { "id": "..." }, ... ] }. For Azure the `id`
      // is the deployment name.
      final data = response.data?['data'];
      if (data is! List) return const [];

      final ids = <String>[];
      for (final entry in data) {
        if (entry is Map && entry['id'] is String) {
          ids.add(entry['id'] as String);
        }
      }
      ids.sort();
      return ids;
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  Exception _mapDioException(DioException e) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return NetworkException(
        message: e.message ?? 'Could not reach the provider endpoint',
      );
    }
    return ServerException(
      message: e.message ?? 'Failed to list provider models',
      statusCode: e.response?.statusCode,
    );
  }
}
