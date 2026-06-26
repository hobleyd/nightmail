import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/ai/ai_provider.dart';
import '../../models/ai/ai_catalog_mapper.dart';

/// Fetches the models.dev catalog (`https://models.dev/api.json`).
///
/// This is the network half of catalog ingestion: it GETs the ~2.4 MB document
/// and returns it either as the raw decoded JSON (for the cold-start blob
/// persisted by `ai_catalog_cache_datasource`) or as mapped [AiProvider]
/// entities. Parsing lives in [AiCatalogMapper]; this datasource only does I/O.
abstract interface class ModelsDevCatalogDatasource {
  /// GET `api.json` and return the raw decoded top-level JSON object
  /// (keyed by provider id). Throws on transport/HTTP failure.
  Future<Map<String, dynamic>> fetchRaw();

  /// Parse a previously fetched raw `api.json` blob (the cold-start cache) into
  /// catalog [AiProvider] entities. Pure CPU work — no I/O.
  List<AiProvider> parse(String rawJson);
}

class ModelsDevCatalogDatasourceImpl implements ModelsDevCatalogDatasource {
  ModelsDevCatalogDatasourceImpl({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// Absolute URL — passed as-is so this works regardless of any `baseUrl`
  /// configured on the injected [Dio] instance.
  static const String apiUrl = 'https://models.dev/api.json';

  @override
  Future<Map<String, dynamic>> fetchRaw() async {
    try {
      final response = await _dio.get<dynamic>(
        apiUrl,
        options: Options(responseType: ResponseType.json),
      );

      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      // Some servers/dio configs deliver the body as a raw string; decode it.
      if (data is String && data.isNotEmpty) {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      }
      throw const ServerException(
        message: 'models.dev catalog returned an unexpected response shape',
      );
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  @override
  List<AiProvider> parse(String rawJson) {
    final decoded = jsonDecode(rawJson);
    if (decoded is Map<String, dynamic>) {
      return AiCatalogMapper.parseCatalog(decoded);
    }
    return const [];
  }

  Exception _mapDioException(DioException e) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.sendTimeout) {
      return NetworkException(
        message: e.message ?? 'Could not reach models.dev',
      );
    }
    return ServerException(
      message: e.message ?? 'Failed to fetch models.dev catalog',
      statusCode: e.response?.statusCode,
    );
  }
}
