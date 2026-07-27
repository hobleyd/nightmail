import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/domain/entities/contact_details.dart';
import 'package:nightmail/domain/usecases/get_contact_details.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/widgets/contact_hover_card.dart';

/// Counts lookups and lets a test hold one open, so the loading state and the
/// fetch-once behaviour are both observable.
class _FakeGetContactDetails extends Fake implements GetContactDetails {
  _FakeGetContactDetails(this._details);

  final ContactDetails? _details;
  int calls = 0;
  Completer<ContactDetails?>? gate;

  @override
  Future<ContactDetails?> call({
    required String address,
    required String accountId,
  }) {
    calls++;
    return gate?.future ?? Future.value(_details);
  }
}

void main() {
  const details = ContactDetails(
    address: 'ada@example.com',
    name: 'Ada Lovelace',
    jobTitle: 'Analytical Engineer',
    department: 'Research',
    companyName: 'Analytical Engines',
    officeLocation: 'Level 3',
    phoneNumbers: ['+61 2 5550 1234'],
  );

  late _FakeGetContactDetails lookup;

  void register(ContactDetails? result) {
    lookup = _FakeGetContactDetails(result);
    sl.registerSingleton<GetContactDetails>(lookup);
  }

  tearDown(() => sl.reset());

  Future<void> pumpTarget(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: ContactHoverTarget(
            address: 'ada@example.com',
            accountId: 'acct-1',
            child: Text('ada@example.com'),
          ),
        ),
      ),
    ));
  }

  /// A mouse parked away from the chip, ready to move onto it.
  Future<TestGesture> mouse(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    return gesture;
  }

  Future<void> hoverChip(WidgetTester tester, TestGesture gesture) async {
    await gesture.moveTo(tester.getCenter(find.text('ada@example.com')));
    await tester.pump();
  }

  Future<void> hoverAway(WidgetTester tester, TestGesture gesture) async {
    await gesture.moveTo(const Offset(5, 5));
    await tester.pump();
  }

  /// The card is the only Material with elevation in this tree.
  Finder card() => find.byWidgetPredicate(
      (w) => w is Material && w.elevation == 8);

  group('ContactHoverTarget — opening', () {
    testWidgets('shows nothing until hovered', (tester) async {
      register(details);
      await pumpTarget(tester);

      expect(card(), findsNothing);
      expect(lookup.calls, 0);
    });

    testWidgets('waits out the hover delay before opening', (tester) async {
      // 400ms of dwell, so brushing past a chip does not flash a card.
      register(details);
      await pumpTarget(tester);
      final gesture = await mouse(tester);

      await hoverChip(tester, gesture);
      await tester.pump(const Duration(milliseconds: 300));

      expect(card(), findsNothing);
      expect(lookup.calls, 0);

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(card(), findsOneWidget);
    });

    testWidgets('leaving before the delay cancels the card', (tester) async {
      register(details);
      await pumpTarget(tester);
      final gesture = await mouse(tester);

      await hoverChip(tester, gesture);
      await tester.pump(const Duration(milliseconds: 200));
      await hoverAway(tester, gesture);
      await tester.pump(const Duration(milliseconds: 600));

      expect(card(), findsNothing);
      expect(lookup.calls, 0, reason: 'no dwell, no lookup');
    });

    testWidgets('shows a spinner while the lookup is in flight',
        (tester) async {
      register(details);
      lookup.gate = Completer<ContactDetails?>();
      await pumpTarget(tester);
      final gesture = await mouse(tester);

      await hoverChip(tester, gesture);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsNothing);

      lookup.gate!.complete(details);
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Ada Lovelace'), findsOneWidget);
    });
  });

  group('ContactHoverTarget — contents', () {
    Future<void> openCard(WidgetTester tester) async {
      await pumpTarget(tester);
      final gesture = await mouse(tester);
      await hoverChip(tester, gesture);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }

    testWidgets('labels every populated field', (tester) async {
      register(details);
      await openCard(tester);

      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Analytical Engineer'), findsOneWidget);
      expect(find.text('Department'), findsOneWidget);
      expect(find.text('Company'), findsOneWidget);
      expect(find.text('Office'), findsOneWidget);
      expect(find.text('Phone'), findsOneWidget);
      expect(find.text('+61 2 5550 1234'), findsOneWidget);
    });

    testWidgets('omits fields the directory did not return', (tester) async {
      register(const ContactDetails(
        address: 'ada@example.com',
        name: 'Ada Lovelace',
      ));
      await openCard(tester);

      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Title'), findsNothing);
      expect(find.text('Department'), findsNothing);
      expect(find.text('Phone'), findsNothing);
    });

    testWidgets('numbers multiple phone numbers', (tester) async {
      register(const ContactDetails(
        address: 'ada@example.com',
        phoneNumbers: ['+61 2 5550 1234', '+61 400 000 000'],
      ));
      await openCard(tester);

      expect(find.text('Phone 1'), findsOneWidget);
      expect(find.text('Phone 2'), findsOneWidget);
      expect(find.text('Phone'), findsNothing);
    });

    testWidgets('renders an empty card for an unknown contact',
        (tester) async {
      register(null);
      await openCard(tester);

      expect(card(), findsOneWidget);
      expect(find.text('Name'), findsNothing);
      expect(find.text('Email'), findsNothing);
    });

    testWidgets('copies a field to the clipboard', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      register(details);
      await openCard(tester);

      await tester.tap(find.byIcon(Icons.copy_rounded).first);
      await tester.pump();

      expect(copied, ['Ada Lovelace']);
    });
  });

  group('ContactHoverTarget — closing', () {
    Future<TestGesture> openCard(WidgetTester tester) async {
      await pumpTarget(tester);
      final gesture = await mouse(tester);
      await hoverChip(tester, gesture);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      return gesture;
    }

    testWidgets('closes shortly after the pointer leaves', (tester) async {
      register(details);
      final gesture = await openCard(tester);

      await hoverAway(tester, gesture);
      await tester.pump(const Duration(milliseconds: 50));
      expect(card(), findsOneWidget, reason: 'a brief gap should not close it');

      await tester.pump(const Duration(milliseconds: 200));
      expect(card(), findsNothing);
    });

    testWidgets('stays open when the pointer moves onto the card itself',
        (tester) async {
      // The 150ms grace is what makes the card reachable at all — the pointer
      // has to cross a gap to get from the chip to it.
      register(details);
      final gesture = await openCard(tester);

      await hoverAway(tester, gesture);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(find.text('Ada Lovelace')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(card(), findsOneWidget);
    });

    testWidgets('does not look the contact up again on a second hover',
        (tester) async {
      register(details);
      final gesture = await openCard(tester);
      expect(lookup.calls, 1);

      await hoverAway(tester, gesture);
      await tester.pump(const Duration(milliseconds: 300));
      await hoverChip(tester, gesture);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(card(), findsOneWidget);
      expect(lookup.calls, 1, reason: 'the first result is cached');
    });
  });
}
