import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html_view/html_view.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/widgets/recipient_input_field.dart';

Widget _wrap({
  required List<String> recipients,
  required ValueChanged<List<String>> onChanged,
  GlobalKey<RecipientInputFieldState>? fieldKey,
  Widget? Function(String address)? chipBadgeBuilder,
}) {
  return MaterialApp(
    home: Scaffold(
      body: RecipientInputField(
        key: fieldKey,
        label: 'To',
        recipients: recipients,
        onChanged: onChanged,
        chipBadgeBuilder: chipBadgeBuilder,
      ),
    ),
  );
}

/// Drives the dropdown through the no-account path, which reads the OS address
/// book directly instead of going through `SearchContacts` and its four
/// repositories.
class _FakeSystemContacts implements SystemContactsRepository {
  List<ContactSuggestion> results = const [];

  @override
  Future<List<ContactSuggestion>> search(String query) async => results;

  @override
  Future<void> warmUp() async {}

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<ContactSuggestion>> fetchAll() async => results;
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

  group('RecipientInputField.chipBadgeBuilder', () {
    testWidgets('renders a badge only for the chips the builder marks',
        (tester) async {
      await tester.pumpWidget(_wrap(
        recipients: const ['alice@example.com', 'bob@example.com'],
        onChanged: (_) {},
        chipBadgeBuilder: (address) => address == 'alice@example.com'
            ? const Icon(Icons.check, size: 12)
            : null,
      ));

      expect(find.byIcon(Icons.check), findsOneWidget);
      // The badge sits inside Alice's chip, alongside her label.
      expect(
        find.ancestor(
          of: find.byIcon(Icons.check),
          matching: find.ancestor(
            of: find.text('alice@example.com'),
            matching: find.byType(Container),
          ),
        ),
        findsWidgets,
      );
    });

    testWidgets('renders no badges when no builder is given', (tester) async {
      await tester.pumpWidget(_wrap(
        recipients: const ['alice@example.com'],
        onChanged: (_) {},
      ));

      expect(find.text('alice@example.com'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });
  });

  // The dropdown is an OverlayPortal, not a ModalRoute, so HtmlViewWidget's own
  // ModalRoute check never fires for it. Without the guard the native WebView2
  // hosting the compose body keeps painting over Flutter on Windows and the
  // list is invisible even though the search returned rows.
  group('RecipientInputField — HtmlViewOverlayGuard', () {
    late _FakeSystemContacts contacts;

    setUp(() {
      contacts = _FakeSystemContacts();
      sl.registerLazySingleton<SystemContactsRepository>(() => contacts);
    });

    tearDown(() async {
      await sl.reset();
      HtmlViewOverlayGuard.activeCount.value = 0;
    });

    testWidgets('is held while the dropdown is up and freed when it closes',
        (tester) async {
      contacts.results = const [
        ContactSuggestion(address: 'alice@example.com', name: 'Alice'),
      ];

      await tester.pumpWidget(_wrap(recipients: const [], onChanged: (_) {}));
      expect(HtmlViewOverlayGuard.activeCount.value, 0);

      await tester.enterText(find.byType(TextField), 'ali');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(find.text('Alice'), findsOneWidget);
      expect(HtmlViewOverlayGuard.activeCount.value, 1);

      // Escape dismisses the list, which must hand the body editor back.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.text('Alice'), findsNothing);
      expect(HtmlViewOverlayGuard.activeCount.value, 0);
    });

    testWidgets('is taken once across a run of keystrokes', (tester) async {
      contacts.results = const [
        ContactSuggestion(address: 'alice@example.com', name: 'Alice'),
      ];

      await tester.pumpWidget(_wrap(recipients: const [], onChanged: (_) {}));

      for (final text in ['a', 'al', 'ali']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();
      }

      // Re-acquiring per keystroke would flicker the body editor.
      expect(HtmlViewOverlayGuard.activeCount.value, 1);
    });

    testWidgets('is freed when a search comes back empty', (tester) async {
      contacts.results = const [
        ContactSuggestion(address: 'alice@example.com', name: 'Alice'),
      ];

      await tester.pumpWidget(_wrap(recipients: const [], onChanged: (_) {}));

      await tester.enterText(find.byType(TextField), 'ali');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(HtmlViewOverlayGuard.activeCount.value, 1);

      contacts.results = const [];
      await tester.enterText(find.byType(TextField), 'aliz');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(HtmlViewOverlayGuard.activeCount.value, 0);
    });

    testWidgets('is freed when the field is disposed with the list open',
        (tester) async {
      contacts.results = const [
        ContactSuggestion(address: 'alice@example.com', name: 'Alice'),
      ];

      await tester.pumpWidget(_wrap(recipients: const [], onChanged: (_) {}));
      await tester.enterText(find.byType(TextField), 'ali');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(HtmlViewOverlayGuard.activeCount.value, 1);

      // Closing the compose window tears the field down without dismissing the
      // dropdown first; leaking the guard would leave every WebView2 in the
      // process permanently hidden.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      expect(HtmlViewOverlayGuard.activeCount.value, 0);
    });
  });
}
