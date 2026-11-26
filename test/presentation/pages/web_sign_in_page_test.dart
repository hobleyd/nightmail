import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
