import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/graph_endpoints.dart';
import '../../models/graph_endpoints_model.dart';

/// Fetches a NightMail Server's endpoint configuration from
/// `<server>/.well-known/nightware`.
///
/// Throws [ServerException] for an address that cannot be a server, a non-2xx
/// answer, or a document that is not valid configuration, and
/// [NetworkException] when the server could not be reached at all —
/// `ServerDiscoveryRepositoryImpl` converts them.
abstract interface class NightwareDiscoveryDatasource {
  Future<GraphEndpoints> discover(String serverUrl);
}

class NightwareDiscoveryDatasourceImpl implements NightwareDiscoveryDatasource {
  NightwareDiscoveryDatasourceImpl({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
            ));

  final Dio _dio;

  @override
  Future<GraphEndpoints> discover(String serverUrl) async {
    final base = GraphEndpointsModel.normaliseServerUrl(serverUrl);
    if (base == null) {
      throw ServerException(
          message: 'Not a valid server address: ${serverUrl.trim()}. '
              'Use https:// (plain http only reaches this computer).');
    }

    final String body;
    try {
      // Plain text and decoded here, not by Dio: a server answering HTML (a
      // proxy's login page, a 200 catch-all) must fail as "not a NightMail
      // Server", not as whatever Dio's transformer makes of it.
      final response = await _dio.get<String>(
        '$base${GraphEndpointsModel.discoveryPath}',
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Accept': 'application/json'},
        ),
      );
      body = response.data ?? '';
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status != null) {
        throw ServerException(
          message: status == 404
              ? '$base is not a NightMail Server (no configuration at '
                  '${GraphEndpointsModel.discoveryPath}).'
              : 'The server answered $status for its configuration.',
          statusCode: status,
        );
      }
      if (e.type == DioExceptionType.badCertificate) {
        throw ServerException(
            message: 'The server\'s certificate is not trusted: $base');
      }
      throw NetworkException(
          message: 'Could not reach $base: ${e.message ?? e.type.name}');
    }

    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw ServerException(
          message: '$base did not return a NightMail Server configuration '
              '(the response is not JSON).');
    }
    return GraphEndpointsModel.fromDiscoveryJson(json, serverUrl: base);
  }
}
