import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/graph_endpoints.dart';

void main() {
  const stored = GraphEndpoints(
    graphBaseUrl: 'https://mail.example.com/graph/v1.0',
    graphBetaBaseUrl: 'https://mail.example.com/graph/beta',
    authorizationEndpoint: 'https://mail.example.com/auth',
    tokenEndpoint: 'https://mail.example.com/token',
    clientId: 'nightmail',
    scopes: ['openid', 'email'],
    serverUrl: 'https://mail.example.com',
  );

  GraphEndpoints rediscovered({
    String? tokenEndpoint,
    List<String>? scopes,
    List<String> filesBaseUrls = const ['https://mail.example.com/cloud'],
  }) =>
      GraphEndpoints(
        graphBaseUrl: stored.graphBaseUrl,
        graphBetaBaseUrl: stored.graphBetaBaseUrl,
        authorizationEndpoint: stored.authorizationEndpoint,
        tokenEndpoint: tokenEndpoint ?? stored.tokenEndpoint,
        clientId: stored.clientId,
        scopes: scopes ?? stored.scopes,
        serverUrl: stored.serverUrl,
        filesBaseUrls: filesBaseUrls,
      );

  test('only new file sites is not a sign-in change, and they are adopted', () {
    final next = rediscovered();
    expect(stored.signInChangeFrom(next), isNull);
    expect(stored.withPublishedFeaturesFrom(next).filesBaseUrls,
        ['https://mail.example.com/cloud']);
  });

  test('names the field that moved, and nothing is adopted', () {
    final moved = rediscovered(tokenEndpoint: 'https://auth.example.com/t');
    expect(stored.signInChangeFrom(moved), 'tokenEndpoint');
    expect(stored.withPublishedFeaturesFrom(moved), same(stored));

    final rescoped = rediscovered(scopes: const ['openid', 'email', 'profile']);
    expect(stored.signInChangeFrom(rescoped), 'scopes');
    expect(stored.withPublishedFeaturesFrom(rescoped), same(stored));
  });
}
