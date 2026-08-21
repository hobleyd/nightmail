import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/infrastructure/auth/oauth_state.dart';

/// The `state` half of both OAuth flows. PKCE stops an injected code from being
/// exchanged; this stops one from being acted on in the first place, which is
/// only worth anything if a redirect that fails to echo the value is refused
/// rather than let past.
void main() {
  group('generateOAuthState', () {
    test('is unguessable per flow, not a constant', () {
      final values = {for (var i = 0; i < 100; i++) generateOAuthState()};
      expect(values, hasLength(100));
    });

    test('survives the query string unchanged, so it compares equal coming '
        'back', () {
      for (var i = 0; i < 50; i++) {
        final state = generateOAuthState();
        final round = Uri.parse('http://127.0.0.1:1/')
            .replace(queryParameters: {'state': state});
        expect(round.queryParameters['state'], state);
        expect(round.query, 'state=$state');
      }
    });
  });

  group('verifyOAuthState', () {
    Uri redirect(Map<String, String> params) =>
        Uri.parse('http://127.0.0.1:34572/').replace(queryParameters: params);

    test('accepts the state it sent', () {
      verifyOAuthState(
        expected: 'abc',
        redirect: redirect({'code': 'x', 'state': 'abc'}),
      );
    });

    test('refuses somebody else\'s state', () {
      expect(
        () => verifyOAuthState(
          expected: 'abc',
          redirect: redirect({'code': 'x', 'state': 'def'}),
        ),
        throwsA(isA<AuthException>()),
      );
    });

    test('refuses a redirect with no state — the whole of the bypass this '
        'closes, and what makes leaving `state` out of the request fail '
        'loudly instead of quietly', () {
      expect(
        () => verifyOAuthState(
          expected: 'abc',
          redirect: redirect({'code': 'x'}),
        ),
        throwsA(isA<AuthException>()),
      );
    });

    test('refuses an empty state', () {
      expect(
        () => verifyOAuthState(
          expected: 'abc',
          redirect: redirect({'code': 'x', 'state': ''}),
        ),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
