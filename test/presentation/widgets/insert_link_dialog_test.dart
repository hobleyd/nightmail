import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/widgets/insert_link_dialog.dart';

void main() {
  /// Opens the dialog over a bare app and returns a getter for its result,
  /// which asserts the future actually completed before reading it.
  Future<String? Function()> open(WidgetTester tester) async {
    String? result;
    var completed = false;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showInsertLinkDialog(context);
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

  group('showInsertLinkDialog', () {
    testWidgets('prompts for a URL', (tester) async {
      await open(tester);

      expect(find.text('Insert Link'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Insert'), findsOneWidget);
    });

    testWidgets('returns null when cancelled', (tester) async {
      final result = await open(tester);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(result(), isNull);
    });

    testWidgets('returns the typed URL on Insert', (tester) async {
      final result = await open(tester);

      await tester.enterText(find.byType(TextField), 'https://example.com');
      await tester.tap(find.text('Insert'));
      await tester.pumpAndSettle();

      expect(result(), 'https://example.com');
    });

    testWidgets('trims surrounding whitespace', (tester) async {
      final result = await open(tester);

      await tester.enterText(find.byType(TextField), '  https://example.com  ');
      await tester.tap(find.text('Insert'));
      await tester.pumpAndSettle();

      expect(result(), 'https://example.com');
    });

    testWidgets('returns an empty string when Insert is pressed with no URL',
        (tester) async {
      // Deliberately distinct from cancelling: an empty string is a cleared
      // link, null is "left alone".
      final result = await open(tester);

      await tester.tap(find.text('Insert'));
      await tester.pumpAndSettle();

      expect(result(), '');
    });

    testWidgets('submitting from the keyboard returns the trimmed URL',
        (tester) async {
      final result = await open(tester);

      await tester.enterText(find.byType(TextField), '  https://example.com ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(result(), 'https://example.com');
    });
  });
}
