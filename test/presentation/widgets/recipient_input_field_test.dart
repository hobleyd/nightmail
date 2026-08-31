import 'package:flutter/gestures.dart';
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
  double leftInset = 0,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: EdgeInsets.only(left: leftInset),
        child: RecipientInputField(
          key: fieldKey,
          label: 'To',
          recipients: recipients,
          onChanged: onChanged,
          chipBadgeBuilder: chipBadgeBuilder,
        ),
      ),
    ),
  );
}

/// The compose window's shape: chips that can be dragged between fields, which
/// is what puts a drag recognizer in the arena against the chip's own tap.
Widget _wrapDraggable({
  required List<String> recipients,
  required ValueChanged<List<String>> onChanged,
}) {
  return MaterialApp(
    home: Scaffold(
      body: RecipientInputField(
        label: 'To',
        recipients: recipients,
        onChanged: onChanged,
        fieldId: 'to',
        onDropAccepted: (_, _) {},
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

  // A guest or recipient added near the right of the window puts the caret
  // there, and the panel is anchored to the caret — so without the shift it
  // hung off the edge and was clipped. See core/utils/dropdown_placement.dart.
  group('RecipientInputField — dropdown placement', () {
    late _FakeSystemContacts contacts;

    setUp(() {
      contacts = _FakeSystemContacts();
      sl.registerLazySingleton<SystemContactsRepository>(() => contacts);
    });

    tearDown(() async {
      await sl.reset();
      HtmlViewOverlayGuard.activeCount.value = 0;
    });

    Future<Rect> showDropdown(WidgetTester tester, double leftInset) async {
      contacts.results = const [
        ContactSuggestion(address: 'alice@example.com', name: 'Alice'),
      ];

      await tester.pumpWidget(_wrap(
        recipients: const [],
        onChanged: (_) {},
        leftInset: leftInset,
      ));

      await tester.enterText(find.byType(TextField), 'ali');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(find.text('Alice'), findsOneWidget);
      return tester.getRect(find.byType(ListView));
    }

    testWidgets('stays inside the window when the input is near the right edge',
        (tester) async {
      final windowWidth = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final rect = await showDropdown(tester, windowWidth - 120);

      expect(rect.right, lessThanOrEqualTo(windowWidth));
      expect(rect.left, greaterThanOrEqualTo(0));
      // Unclipped means it kept its full width, not that it was squeezed.
      expect(rect.width, 400);
    });

    testWidgets('is left where it falls when there is room', (tester) async {
      final rect = await showDropdown(tester, 0);

      final field = tester.getRect(find.byType(TextField));
      expect(rect.left, moreOrLessEquals(field.left, epsilon: 0.5));
    });
  });

  // Clicking a chip and pressing Delete. The chip is a Draggable, and
  // ImmediateMultiDragGestureRecognizer hard-codes its hit slop to one logical
  // pixel for a mouse — so a click that drifts, as a trackpad click nearly
  // always does, started a drag, won the arena, and the chip's tap never fired.
  // Nothing was selected and Delete had nothing to act on.
  group('RecipientInputField — chip selection', () {
    /// Two fields side by side, so a chip can be dragged between them.
    Widget twoFields({
      required List<String> to,
      required List<String> cc,
      required ValueChanged<List<String>> onToChanged,
      required ValueChanged<List<String>> onCcChanged,
      required RecipientDropAccepted onDropToCc,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              RecipientInputField(
                label: 'To',
                recipients: to,
                fieldId: 'to',
                onChanged: onToChanged,
                onDropAccepted: (_, _) {},
              ),
              RecipientInputField(
                label: 'Cc',
                recipients: cc,
                fieldId: 'cc',
                onChanged: onCcChanged,
                onDropAccepted: onDropToCc,
              ),
            ],
          ),
        ),
      );
    }

    /// A mouse press on [finder] that drifts [drift] pixels before releasing.
    ///
    /// The drift is the test, not incidental setup: a plain `tester.tap` uses
    /// a touch pointer, whose slop is 18px, and passes against the bug.
    Future<void> clickWithDrift(
      WidgetTester tester,
      Finder finder, {
      double drift = 1.5,
    }) async {
      final gesture = await tester.startGesture(
        tester.getCenter(finder),
        kind: PointerDeviceKind.mouse,
      );
      if (drift > 0) await gesture.moveBy(Offset(drift, 0));
      await gesture.up();
      await tester.pump();
    }

    testWidgets('a drifting mouse click then Delete removes the chip',
        (tester) async {
      var recipients = ['alice@example.com', 'bob@example.com'];
      await tester.pumpWidget(StatefulBuilder(
        builder: (_, setState) => _wrapDraggable(
          recipients: recipients,
          onChanged: (r) => setState(() => recipients = r),
        ),
      ));

      await clickWithDrift(tester, find.text('alice@example.com'));
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(recipients, ['bob@example.com']);
    });

    testWidgets('a drifting mouse click then Backspace removes the chip',
        (tester) async {
      var recipients = ['alice@example.com', 'bob@example.com'];
      await tester.pumpWidget(StatefulBuilder(
        builder: (_, setState) => _wrapDraggable(
          recipients: recipients,
          onChanged: (r) => setState(() => recipients = r),
        ),
      ));

      await clickWithDrift(tester, find.text('bob@example.com'));
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(recipients, ['alice@example.com']);
    });

    testWidgets('a still mouse click still selects', (tester) async {
      var recipients = ['alice@example.com', 'bob@example.com'];
      await tester.pumpWidget(StatefulBuilder(
        builder: (_, setState) => _wrapDraggable(
          recipients: recipients,
          onChanged: (r) => setState(() => recipients = r),
        ),
      ));

      await clickWithDrift(tester, find.text('alice@example.com'), drift: 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(recipients, ['bob@example.com']);
    });

    // The chip-key Focus is an ancestor of the TextField, so a selection left
    // set answers Delete even once the user is typing again — and the field's
    // own tap, which clears it, never sees a tap the TextField took.
    testWidgets('clicking into the input drops the selection', (tester) async {
      var recipients = ['alice@example.com', 'bob@example.com'];
      await tester.pumpWidget(StatefulBuilder(
        builder: (_, setState) => _wrapDraggable(
          recipients: recipients,
          onChanged: (r) => setState(() => recipients = r),
        ),
      ));

      await clickWithDrift(tester, find.text('alice@example.com'));
      await clickWithDrift(tester, find.byType(TextField), drift: 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(recipients, ['alice@example.com', 'bob@example.com']);
    });

    // A completed drag takes the chip out of the list, so the index would name
    // whichever recipient shuffled up into its place.
    testWidgets('dragging a chip to another field drops the selection',
        (tester) async {
      var to = ['alice@example.com', 'bob@example.com'];
      var cc = <String>[];

      await tester.pumpWidget(StatefulBuilder(
        builder: (_, setState) => twoFields(
          to: to,
          cc: cc,
          onToChanged: (r) => setState(() => to = r),
          onCcChanged: (r) => setState(() => cc = r),
          onDropToCc: (address, _) => setState(() {
            to = List.of(to)..remove(address);
            cc = List.of(cc)..add(address);
          }),
        ),
      ));

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('alice@example.com')),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(tester.getCenter(find.byType(TextField).last));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(to, ['bob@example.com']);
      expect(cc, ['alice@example.com']);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(to, ['bob@example.com'], reason: 'nothing is selected any more');
      expect(cc, ['alice@example.com']);
    });

    // The path that already worked before any of this, and which the
    // clear-on-input-focus rule sits directly beside.
    testWidgets('Backspace in an empty input selects the last chip, and a '
        'second Backspace removes it', (tester) async {
      var recipients = ['alice@example.com', 'bob@example.com'];
      await tester.pumpWidget(StatefulBuilder(
        builder: (_, setState) => _wrapDraggable(
          recipients: recipients,
          onChanged: (r) => setState(() => recipients = r),
        ),
      ));

      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(recipients, ['alice@example.com', 'bob@example.com'],
          reason: 'the first Backspace only selects');

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(recipients, ['alice@example.com']);
    });
  });
}
