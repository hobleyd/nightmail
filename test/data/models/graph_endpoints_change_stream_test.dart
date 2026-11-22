import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/models/graph_endpoints_model.dart';

Map<String, dynamic> _discovery({Object? changesUrl}) => {
      'graphBaseUrl': 'https://mail.example.com/graph/v1.0',
      'graphBetaBaseUrl': 'https://mail.example.com/graph/beta',
      'authorizationEndpoint': 'https://auth.example.com/authorize',
      'tokenEndpoint': 'https://auth.example.com/token',
      'clientId': 'nightmail',
      'scopes': ['openid'],
      'changesUrl': ?changesUrl,
    };

void main() {
  const serverUrl = 'https://mail.example.com';

  test('a change stream on the Graph root is kept, trailing slash stripped',
      () {
    final endpoints = GraphEndpointsModel.fromDiscoveryJson(
        _discovery(
            changesUrl: 'https://mail.example.com/graph/nightware/v1/changes/'),
        serverUrl: serverUrl);

    expect(endpoints.changesUrl,
        'https://mail.example.com/graph/nightware/v1/changes');
  });

  test('absent, another host, another scheme or port, or not a URL is dropped',
      () {
    for (final raw in <Object?>[
      null,
      'https://evil.example.net/changes',
      'http://mail.example.com/graph/nightware/v1/changes',
      'https://mail.example.com:8443/graph/nightware/v1/changes',
      'https://mail.example.com/changes?x=1',
      42,
    ]) {
      expect(
          GraphEndpointsModel.fromDiscoveryJson(_discovery(changesUrl: raw),
                  serverUrl: serverUrl)
              .changesUrl,
          isNull,
          reason: '$raw');
    }
  });

  test('survives storage, and an account saved before it loads without one',
      () {
    final endpoints = GraphEndpointsModel.fromDiscoveryJson(
        _discovery(
            changesUrl: 'https://mail.example.com/graph/nightware/v1/changes'),
        serverUrl: serverUrl);
    final stored = GraphEndpointsModel.toStorageJson(endpoints);

    expect(GraphEndpointsModel.fromStorageJson(stored), endpoints);
    expect(
        GraphEndpointsModel.fromStorageJson(
                Map.of(stored)..remove('changesUrl'))
            .changesUrl,
        isNull);
  });

  test('rediscovery adopts a newly published change stream', () {
    final before = GraphEndpointsModel.fromDiscoveryJson(_discovery(),
        serverUrl: serverUrl);
    final now = GraphEndpointsModel.fromDiscoveryJson(
        _discovery(
            changesUrl: 'https://mail.example.com/graph/nightware/v1/changes'),
        serverUrl: serverUrl);

    expect(before.withPublishedFeaturesFrom(now).changesUrl, now.changesUrl);
    expect(identical(now.withPublishedFeaturesFrom(now), now), isTrue);
  });
}
