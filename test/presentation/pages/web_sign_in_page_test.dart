import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/graph_endpoints.dart';
import 'package:nightmail/domain/usecases/discover_nightware_server.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/pages/account_selection_page.dart';
import 'package:nightmail/presentation/pages/web_sign_in_page.dart';

void main() {
  group('noAccountsPage', () {
    test('the web build offers only its server sign-in, never the chooser',
        () {
      expect(noAccountsPage(isWeb: true), isA<WebSignInPage>());
    });

    test('a native app offers every provider', () {
      expect(noAccountsPage(isWeb: false), isA<AccountSelectionPage>());
    });
  });

  testWidgets('WebSignInPage offers one sign-in and no provider choice',
      (tester) async {
    // An empty server skips discovery, so nothing here needs the locator.
    await tester.pumpWidget(
      const MaterialApp(home: WebSignInPage(server: '')),
    );

    expect(find.widgetWithText(ElevatedButton, 'Sign in'), findsOneWidget);
    expect(find.byType(ElevatedButton), findsOneWidget);
    expect(find.text('Choose your email provider'), findsNothing);
    expect(find.text('Gmail'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  group('with a server configured', () {
    late Completer<Either<Failure, GraphEndpoints>> discovery;
    late List<String> asked;

    // Each test makes its own Completer: one made here, outside the test's
    // fake-async zone, resolves on the real microtask queue, after the
    // test's pumps.
    setUp(() {
      asked = [];
      sl.registerSingleton<DiscoverNightwareServer>(
        _FakeDiscovery((url) {
          asked.add(url);
          return discovery.future;
        }),
      );
    });

    tearDown(() => sl.reset());

    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
          const MaterialApp(
            home: WebSignInPage(server: 'https://nightware.example.com'),
          ),
        );

    ElevatedButton button(WidgetTester tester) =>
        tester.widget<ElevatedButton>(find.byType(ElevatedButton));

    testWidgets('discovers on open; Sign in waits for it', (tester) async {
      discovery = Completer();
      await pump(tester);

      expect(asked, ['https://nightware.example.com']);
      expect(find.text('Sign in with your account on nightware.example.com.'),
          findsOneWidget);
      expect(button(tester).onPressed, isNull);

      discovery.complete(right(const GraphEndpoints(
        graphBaseUrl: 'https://nightware.example.com/graph/v1.0',
        graphBetaBaseUrl: 'https://nightware.example.com/graph/beta',
        authorizationEndpoint: 'https://nightware.example.com/auth',
        tokenEndpoint: 'https://nightware.example.com/token',
        clientId: 'nightmail',
      )));
      await tester.pumpAndSettle();

      expect(button(tester).onPressed, isNotNull);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('a failed discovery says why and can be retried',
        (tester) async {
      discovery = Completer();
      await pump(tester);
      discovery.complete(left(const NetworkFailure(message: 'unreachable')));
      await tester.pumpAndSettle();

      expect(find.text('unreachable'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Try again'), findsOneWidget);

      discovery = Completer();
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(asked, hasLength(2));
      // Offering no address field is the gate: nothing to type another
      // server into.
      expect(find.byType(TextField), findsNothing);
    });
  });
}

class _FakeDiscovery implements DiscoverNightwareServer {
  _FakeDiscovery(this._answer);

  final Future<Either<Failure, GraphEndpoints>> Function(String) _answer;

  @override
  Future<Either<Failure, GraphEndpoints>> call(String params) =>
      _answer(params);
}
