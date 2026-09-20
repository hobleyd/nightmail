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

  const advancedToggle = 'Use a custom app registration';

  group('showClientIdDialog', () {
    testWidgets('names the provider and shows its help text', (tester) async {
      await open(tester);

      expect(find.text('Sign in with Gmail'), findsOneWidget);
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

    testWidgets('refuses to continue with a blank client id', (tester) async {
      await open(tester);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Enter a Client ID'), findsOneWidget);
      expect(find.text('Sign in with Gmail'), findsOneWidget,
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

      expect(find.text('Sign in with Gmail'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result(), isNull);
    });
  });

  // BYOA fields (Client ID/Secret) are hidden behind a toggle whenever there
  // is an actual default to hide them behind — i.e. whenever the caller
  // passes a non-null initialValue. With no default at all (initialValue:
  // null, the case exercised by the group above) there is nothing to hide
  // behind, so the fields show immediately instead.
  group('showClientIdDialog — hides BYOA fields when a default exists', () {
    testWidgets('shows a toggle instead of the client id field', (tester) async {
      await open(tester, initialValue: 'default-id');

      expect(fieldLabelled('Client ID'), findsNothing);
      expect(find.text(advancedToggle), findsOneWidget);
    });

    testWidgets('continuing without opening the toggle uses the default id',
        (tester) async {
      final result = await open(tester, initialValue: 'default-id');

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(result()!.clientId, 'default-id');
    });

    testWidgets('the toggle reveals the client id field pre-filled with the default',
        (tester) async {
      await open(tester, initialValue: 'default-id');

      await tester.tap(find.text(advancedToggle));
      await tester.pumpAndSettle();

      expect(fieldLabelled('Client ID'), findsOneWidget);
      expect(find.text('default-id'), findsOneWidget);
    });

    testWidgets('editing the field after opening the toggle overrides the default',
        (tester) async {
      final result = await open(tester, initialValue: 'default-id');

      await tester.tap(find.text(advancedToggle));
      await tester.pumpAndSettle();
      await tester.enterText(fieldLabelled('Client ID'), 'custom-id');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(result()!.clientId, 'custom-id');
    });

    testWidgets('a required secret also stays hidden until the toggle is opened',
        (tester) async {
      final result = await open(
        tester,
        initialValue: 'default-id',
        requireSecret: true,
        initialSecret: 'default-secret',
      );

      expect(fieldLabelled('Client Secret'), findsNothing);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(result()!.clientId, 'default-id');
      expect(result()!.clientSecret, 'default-secret');
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
