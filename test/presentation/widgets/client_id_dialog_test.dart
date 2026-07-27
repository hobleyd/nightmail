import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/client_id_dialog.dart';

void main() {
  /// Opens the dialog over a bare app and returns a getter for its result,
  /// which asserts the future actually completed before reading it.
  Future<OAuthCredentials? Function()> open(
    WidgetTester tester, {
    String provider = 'Gmail',
    String helpText = 'Paste the client ID from the Google console.',
    String? initialValue,
    bool requireSecret = false,
    String? initialSecret,
  }) async {
    OAuthCredentials? result;
    var completed = false;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showClientIdDialog(
                context,
                provider: provider,
                helpText: helpText,
                initialValue: initialValue,
                requireSecret: requireSecret,
                initialSecret: initialSecret,
              );
              completed = true;
            },
            child: const Text('open the dialog'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open the dialog'));
    await tester.pumpAndSettle();

    return () {
      expect(completed, isTrue, reason: 'the dialog never resolved');
      return result;
    };
  }

  Finder fieldLabelled(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(TextFormField));

  group('showClientIdDialog', () {
    testWidgets('names the provider and shows its help text', (tester) async {
      await open(tester);

      expect(find.text('Gmail — OAuth Credentials'), findsOneWidget);
      expect(
        find.text('Paste the client ID from the Google console.'),
        findsOneWidget,
      );
    });

    testWidgets('returns null when cancelled', (tester) async {
      final result = await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result(), isNull);
    });

    testWidgets('returns the entered client id', (tester) async {
      final result = await open(tester);

      await tester.enterText(fieldLabelled('Client ID'), 'abc-123');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(result()!.clientId, 'abc-123');
    });

    testWidgets('trims the client id', (tester) async {
      final result = await open(tester);

      await tester.enterText(fieldLabelled('Client ID'), '  abc-123  ');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(result()!.clientId, 'abc-123');
    });

    testWidgets('pre-fills the client id when editing an existing one',
        (tester) async {
      await open(tester, initialValue: 'existing-id');

      expect(find.text('existing-id'), findsOneWidget);
    });

    testWidgets('refuses to continue with a blank client id', (tester) async {
      await open(tester);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a Client ID'), findsOneWidget);
      expect(find.text('Gmail — OAuth Credentials'), findsOneWidget,
          reason: 'the dialog should stay open');
    });

    testWidgets('refuses to continue with a whitespace-only client id',
        (tester) async {
      await open(tester);

      await tester.enterText(fieldLabelled('Client ID'), '   ');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a Client ID'), findsOneWidget);
    });

    testWidgets('cannot be dismissed by tapping outside', (tester) async {
      // barrierDismissible is off: half-entered credentials leave the caller
      // with nothing to act on.
      final result = await open(tester);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(find.text('Gmail — OAuth Credentials'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result(), isNull);
    });
  });

  group('showClientIdDialog — with a client secret', () {
    testWidgets('asks for a secret only when one is required', (tester) async {
      await open(tester);
      expect(fieldLabelled('Client Secret'), findsNothing);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await open(tester, requireSecret: true);
      expect(fieldLabelled('Client Secret'), findsOneWidget);
    });

    testWidgets('returns both credentials', (tester) async {
      final result = await open(tester, requireSecret: true);

      await tester.enterText(fieldLabelled('Client ID'), 'abc-123');
      await tester.enterText(fieldLabelled('Client Secret'), 'shhh');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(result()!.clientId, 'abc-123');
      expect(result()!.clientSecret, 'shhh');
    });

    testWidgets('refuses to continue with a blank secret', (tester) async {
      await open(tester, requireSecret: true);

      await tester.enterText(fieldLabelled('Client ID'), 'abc-123');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a Client Secret'), findsOneWidget);
    });

    testWidgets('obscures the secret as it is typed', (tester) async {
      await open(tester, requireSecret: true);

      final field = tester.widget<TextField>(
        find.descendant(
          of: fieldLabelled('Client Secret'),
          matching: find.byType(TextField),
        ),
      );

      expect(field.obscureText, isTrue);
    });

    testWidgets('reports no secret when one was not required', (tester) async {
      // The caller uses null to mean "this provider has no secret", so a stale
      // value from the controller must not leak through.
      final result = await open(tester, initialSecret: 'leftover');

      await tester.enterText(fieldLabelled('Client ID'), 'abc-123');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(result()!.clientSecret, isNull);
    });
  });
}
