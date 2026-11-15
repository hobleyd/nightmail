import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/remote/nightware_discovery_datasource.dart';
import 'package:nightmail/data/models/graph_endpoints_model.dart';
import 'package:nightmail/data/repositories/server_discovery_repository_impl.dart';
import 'package:nightmail/domain/entities/graph_endpoints.dart';
import 'package:nightmail/domain/usecases/discover_nightware_server.dart';

/// `/.well-known/nightware` is the contract a NightMail Server publishes. Every
/// URL in it is handed the account's tokens, so a malformed or non-https
/// document has to be refused here, before a sign-in is ever opened.
void main() {
  const valid = {
    'graphBaseUrl': 'https://mail.example.com/graph/v1.0',
    'graphBetaBaseUrl': 'https://mail.example.com/graph/beta/',
    'authorizationEndpoint': 'https://mail.example.com/oauth2/authorize',
    'tokenEndpoint': 'https://mail.example.com/oauth2/token',
    'clientId': 'nightmail',
    'scopes': ['openid', 'email', 'profile', 'offline_access'],
  };

  /// A Dio answering every request with [status] and [body], recording what
  /// was asked in [seen].
  Dio stub(int status, String body, {List<RequestOptions>? seen}) {
    final dio = Dio();
    dio.httpClientAdapter = _StubAdapter((options) async {
      seen?.add(options);
      return ResponseBody.fromString(body, status, headers: const {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    });
    return dio;
  }

  Dio unreachable() {
    final dio = Dio();
    dio.httpClientAdapter = _StubAdapter((options) async {
      throw DioException.connectionError(
          requestOptions: options, reason: 'Failed host lookup');
    });
    return dio;
  }

  group('NightwareDiscoveryDatasourceImpl', () {
    test('fetches <server>/.well-known/nightware and parses every field',
        () async {
      final seen = <RequestOptions>[];
      final ds = NightwareDiscoveryDatasourceImpl(
          dio: stub(200, jsonEncode(valid), seen: seen));

      final endpoints = await ds.discover('  mail.example.com/  ');

      expect(seen.single.uri.toString(),
          'https://mail.example.com/.well-known/nightware');
      expect(
        endpoints,
        const GraphEndpoints(
          graphBaseUrl: 'https://mail.example.com/graph/v1.0',
          // Trailing slash stripped: paths are appended with a leading one.
          graphBetaBaseUrl: 'https://mail.example.com/graph/beta',
          authorizationEndpoint: 'https://mail.example.com/oauth2/authorize',
          tokenEndpoint: 'https://mail.example.com/oauth2/token',
          clientId: 'nightmail',
          scopes: ['openid', 'email', 'profile', 'offline_access'],
          serverUrl: 'https://mail.example.com',
        ),
      );
      expect(endpoints.isMicrosoft, isFalse);
    });

    test('a server on a sub-path keeps it', () async {
      final seen = <RequestOptions>[];
      final ds = NightwareDiscoveryDatasourceImpl(
          dio: stub(200, jsonEncode(valid), seen: seen));
      await ds.discover('https://example.com/nightware/');
      expect(seen.single.uri.toString(),
          'https://example.com/nightware/.well-known/nightware');
    });

    for (final field in valid.keys) {
      test('a document missing "$field" is refused', () async {
        final doc = Map<String, Object>.of(valid)..remove(field);
        final ds = NightwareDiscoveryDatasourceImpl(
            dio: stub(200, jsonEncode(doc)));
        await expectLater(
          ds.discover('mail.example.com'),
          throwsA(isA<ServerException>()
              .having((e) => e.message, 'message', contains(field))),
        );
      });
    }

    test('empty strings and empty scope lists count as missing', () async {
      for (final doc in [
        {...valid, 'clientId': '  '},
        {...valid, 'tokenEndpoint': ''},
        {...valid, 'scopes': <String>[]},
        {
          ...valid,
          'scopes': ['openid', 3],
        },
      ]) {
        final ds =
            NightwareDiscoveryDatasourceImpl(dio: stub(200, jsonEncode(doc)));
        await expectLater(
            ds.discover('mail.example.com'), throwsA(isA<ServerException>()));
      }
    });

    test('an endpoint that is not https is refused — it would get the tokens',
        () async {
      final ds = NightwareDiscoveryDatasourceImpl(
        dio: stub(
            200,
            jsonEncode({
              ...valid,
              'tokenEndpoint': 'http://mail.example.com/oauth2/token',
            })),
      );
      await expectLater(
        ds.discover('mail.example.com'),
        throwsA(isA<ServerException>()
            .having((e) => e.message, 'message', contains('tokenEndpoint'))),
      );
    });

    test('plain http is accepted for a server on this machine', () async {
      final local = {
        for (final e in valid.entries)
          e.key: e.value is String && (e.value as String).startsWith('https')
              ? (e.value as String)
                  .replaceFirst('https://mail.example.com', 'http://localhost:5000')
              : e.value,
      };
      final ds =
          NightwareDiscoveryDatasourceImpl(dio: stub(200, jsonEncode(local)));
      final endpoints = await ds.discover('http://localhost:5000');
      expect(endpoints.graphBaseUrl, 'http://localhost:5000/graph/v1.0');
      expect(endpoints.serverUrl, 'http://localhost:5000');
    });

    test('a non-200 answer is a ServerException carrying the status',
        () async {
      for (final status in [404, 500]) {
        final ds = NightwareDiscoveryDatasourceImpl(dio: stub(status, '{}'));
        await expectLater(
          ds.discover('mail.example.com'),
          throwsA(isA<ServerException>()
              .having((e) => e.statusCode, 'statusCode', status)),
        );
      }
    });

    test('a body that is not JSON is refused as not a NightMail Server',
        () async {
      final ds = NightwareDiscoveryDatasourceImpl(
          dio: stub(200, '<html><body>Sign in</body></html>'));
      await expectLater(
        ds.discover('mail.example.com'),
        throwsA(isA<ServerException>()
            .having((e) => e.message, 'message', contains('not JSON'))),
      );
    });

    test('JSON that is not an object is refused', () async {
      final ds = NightwareDiscoveryDatasourceImpl(dio: stub(200, '[1,2]'));
      await expectLater(
          ds.discover('mail.example.com'), throwsA(isA<ServerException>()));
    });

    test('an unreachable server is a NetworkException, not a server error',
        () async {
      final ds = NightwareDiscoveryDatasourceImpl(dio: unreachable());
      await expectLater(
          ds.discover('mail.example.com'), throwsA(isA<NetworkException>()));
    });

    test('an address that cannot be a server is refused without a request',
        () async {
      final seen = <RequestOptions>[];
      final ds = NightwareDiscoveryDatasourceImpl(
          dio: stub(200, jsonEncode(valid), seen: seen));
      for (final input in [
        '',
        '   ',
        'http://mail.example.com',
        'ftp://mail.example.com',
      ]) {
        await expectLater(
            ds.discover(input), throwsA(isA<ServerException>()));
      }
      expect(seen, isEmpty);
    });
  });

  group('filesBaseUrls (optional)', () {
    GraphEndpoints parse(Object? files) => GraphEndpointsModel.fromDiscoveryJson(
          {...valid, 'filesBaseUrls': ?files},
          serverUrl: 'https://mail.example.com',
        );

    test('absent means no file sites, and the document is still valid', () {
      expect(parse(null).filesBaseUrls, isEmpty);
    });

    test('usable entries are kept, trailing slashes stripped, duplicates dropped',
        () {
      expect(
        parse([
          'https://cloud.example.com/',
          'https://files.example.com/nextcloud',
          'https://cloud.example.com',
          'http://cloud.lan',
        ]).filesBaseUrls,
        [
          'https://cloud.example.com',
          'https://files.example.com/nextcloud',
          'http://cloud.lan',
        ],
      );
    });

    test('a malformed list or entry is ignored rather than refusing the server',
        () {
      expect(parse('https://cloud.example.com').filesBaseUrls, isEmpty);
      expect(
        parse([
          42,
          '',
          'cloud.example.com',
          'ftp://cloud.example.com',
          'https://cloud.example.com/?x=1',
          'https://cloud.example.com/#f',
          'https://user:pw@cloud.example.com',
          'https://ok.example.com',
        ]).filesBaseUrls,
        ['https://ok.example.com'],
      );
    });

    test('round-trips through the stored copy; none stores nothing', () {
      final endpoints = parse(['https://cloud.example.com']);
      final stored = GraphEndpointsModel.toStorageJson(endpoints);
      expect(stored['filesBaseUrls'], ['https://cloud.example.com']);
      expect(GraphEndpointsModel.fromStorageJson(stored), endpoints);
      expect(
          GraphEndpointsModel.toStorageJson(parse(null))
              .containsKey('filesBaseUrls'),
          isFalse);
    });
  });

  group('GraphEndpointsModel storage JSON', () {
    test('round-trips a discovered configuration', () {
      final endpoints = GraphEndpointsModel.fromDiscoveryJson(valid,
          serverUrl: 'https://mail.example.com');
      expect(
        GraphEndpointsModel.fromStorageJson(
            jsonDecode(jsonEncode(GraphEndpointsModel.toStorageJson(endpoints)))
                as Map<String, dynamic>),
        endpoints,
      );
    });

    test('never throws on a damaged copy, and never reads as Microsoft', () {
      // AccountStorage.loadAccounts answers *no accounts* on any throw.
      final endpoints = GraphEndpointsModel.fromStorageJson(const {
        'graphBaseUrl': 3,
        'scopes': 'openid',
      });
      expect(endpoints.isMicrosoft, isFalse);
      expect(endpoints.graphBaseUrl, '');
      expect(endpoints.scopes, isNull);
    });
  });

  group('DiscoverNightwareServer', () {
    DiscoverNightwareServer useCase(Dio dio) => DiscoverNightwareServer(
          ServerDiscoveryRepositoryImpl(
            datasource: NightwareDiscoveryDatasourceImpl(dio: dio),
          ),
        );

    test('valid configuration comes back Right', () async {
      final result =
          await useCase(stub(200, jsonEncode(valid)))('mail.example.com');
      expect(result.isRight(), isTrue);
      expect(result.getOrElse((_) => throw StateError('left')).clientId,
          'nightmail');
    });

    test('a non-200 answer is a ServerFailure with the status', () async {
      final result = await useCase(stub(404, '{}'))('mail.example.com');
      expect(
        result,
        isA<Left<Failure, GraphEndpoints>>().having(
            (l) => l.value,
            'failure',
            isA<ServerFailure>()
                .having((f) => f.statusCode, 'statusCode', 404)),
      );
    });

    test('bad JSON and missing fields are ServerFailures', () async {
      expect(
        (await useCase(stub(200, 'nope'))('mail.example.com'))
            .getLeft()
            .toNullable(),
        isA<ServerFailure>(),
      );
      expect(
        (await useCase(stub(200, '{"clientId":"x"}'))('mail.example.com'))
            .getLeft()
            .toNullable(),
        isA<ServerFailure>(),
      );
    });

    test('an unreachable server is a NetworkFailure', () async {
      expect(
        (await useCase(unreachable())('mail.example.com'))
            .getLeft()
            .toNullable(),
        isA<NetworkFailure>(),
      );
    });
  });
}

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this._respond);

  final Future<ResponseBody> Function(RequestOptions) _respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      _respond(options);

  @override
  void close({bool force = false}) {}
}
