import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/recipient_input_field.dart';

Widget _wrap({
  required List<String> recipients,
  required ValueChanged<List<String>> onChanged,
  GlobalKey<RecipientInputFieldState>? fieldKey,
}) {
  return MaterialApp(
    home: Scaffold(
      body: RecipientInputField(
        key: fieldKey,
        label: 'To',
        recipients: recipients,
        onChanged: onChanged,
      ),
    ),
  );
}

void main() {
  group('RecipientInputField.flush()', () {
    testWidgets('commits typed text and calls onChanged', (tester) async {
      final key = GlobalKey<RecipientInputFieldState>();
      List<String> result = [];

      await tester.pumpWidget(_wrap(
        fieldKey: key,
        recipients: const [],
        onChanged: (r) => result = r,
      ));

      await tester.enterText(find.byType(TextField), 'user@example.com');

      key.currentState!.flush();

      expect(result, ['user@example.com']);
    });

    testWidgets('is a no-op when the text field is empty', (tester) async {
      final key = GlobalKey<RecipientInputFieldState>();
      var called = false;

      await tester.pumpWidget(_wrap(
        fieldKey: key,
        recipients: const [],
        onChanged: (_) => called = true,
      ));

      key.currentState!.flush();

      expect(called, isFalse);
    });

    testWidgets('trims whitespace from the typed address', (tester) async {
      final key = GlobalKey<RecipientInputFieldState>();
      List<String> result = [];

      await tester.pumpWidget(_wrap(
        fieldKey: key,
        recipients: const [],
        onChanged: (r) => result = r,
      ));

      await tester.enterText(find.byType(TextField), '  user@example.com  ');

      key.currentState!.flush();

      expect(result, ['user@example.com']);
    });

    testWidgets('strips trailing comma from typed address', (tester) async {
      final key = GlobalKey<RecipientInputFieldState>();
      List<String> result = [];

      await tester.pumpWidget(_wrap(
        fieldKey: key,
        recipients: const [],
        onChanged: (r) => result = r,
      ));

      await tester.enterText(find.byType(TextField), 'user@example.com,');

      key.currentState!.flush();

      expect(result, ['user@example.com']);
    });

    testWidgets('appends to existing committed recipients', (tester) async {
      final key = GlobalKey<RecipientInputFieldState>();
      List<String> result = [];

      await tester.pumpWidget(_wrap(
        fieldKey: key,
        recipients: const ['alice@example.com'],
        onChanged: (r) => result = r,
      ));

      await tester.enterText(find.byType(TextField), 'bob@example.com');

      key.currentState!.flush();

      expect(result, ['alice@example.com', 'bob@example.com']);
    });

    testWidgets('clears the text field after flushing', (tester) async {
      final key = GlobalKey<RecipientInputFieldState>();

      await tester.pumpWidget(_wrap(
        fieldKey: key,
        recipients: const [],
        onChanged: (_) {},
      ));

      await tester.enterText(find.byType(TextField), 'user@example.com');
      expect(find.text('user@example.com'), findsOneWidget);

      key.currentState!.flush();
      await tester.pump();

      expect(find.text('user@example.com'), findsNothing);
    });
  });

  group('RecipientInputField — focus-loss commit', () {
    testWidgets('commits typed text when field loses focus', (tester) async {
      List<String> result = [];
      final otherFocus = FocusNode();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              RecipientInputField(
                label: 'To',
                recipients: const [],
                onChanged: (r) => result = r,
              ),
              Focus(focusNode: otherFocus, child: const SizedBox()),
            ],
          ),
        ),
      ));

      await tester.enterText(find.byType(TextField), 'user@example.com');

      // Move focus away — triggers _onInputFocusChanged → _flushInput
      otherFocus.requestFocus();
      await tester.pump();

      expect(result, ['user@example.com']);
    });

    testWidgets('Enter key commits typed text', (tester) async {
      List<String> result = [];

      await tester.pumpWidget(_wrap(
        recipients: const [],
        onChanged: (r) => result = r,
      ));

      await tester.enterText(find.byType(TextField), 'user@example.com');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(result, ['user@example.com']);
    });

    testWidgets('typing a comma commits the preceding address', (tester) async {
      List<String> result = [];

      await tester.pumpWidget(_wrap(
        recipients: const [],
        onChanged: (r) => result = r,
      ));

      // Simulate typing "user@example.com,"
      await tester.enterText(find.byType(TextField), 'user@example.com,');
      await tester.pump();

      expect(result, ['user@example.com']);
    });
  });
}
