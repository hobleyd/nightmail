import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/presentation/widgets/commitments/track_commitment_dialog.dart';

/// The "Track this message" chooser: the kinds offered follow the message's
/// direction, the defaults are the likely case, and the result is what was
/// picked.
void main() {
  Email email({required bool outgoing}) => Email(
        id: 'm1',
        subject: 'Invoice approval',
        from: outgoing
            ? const EmailAddress(address: 'me@example.com', name: 'Me')
            : const EmailAddress(address: 'jesse@client.com', name: 'Jesse'),
        toRecipients: [
          outgoing
              ? const EmailAddress(address: 'jesse@client.com', name: 'Jesse')
              : const EmailAddress(address: 'me@example.com', name: 'Me'),
        ],
        ccRecipients: const [],
        bodyPreview: '',
        body: '',
        bodyType: EmailBodyType.text,
        isRead: true,
        receivedDateTime: DateTime(2026, 10, 5, 8),
        importance: EmailImportance.normal,
      );

  Future<_Harness> pump(WidgetTester tester, {required bool outgoing}) async {
    final h = _Harness();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  h.opened = true;
                  h.result = await TrackCommitmentDialog.show(
                    context,
                    email: email(outgoing: outgoing),
                    outgoing: outgoing,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return h;
  }

  testWidgets('a received message offers "needs my action" (default) and '
      '"waiting on them", due this week by default', (tester) async {
    final h = await pump(tester, outgoing: false);

    expect(find.text('Track this message'), findsOneWidget);
    expect(find.text('Jesse · Invoice approval'), findsOneWidget);
    expect(find.text('Needs my action'), findsOneWidget);
    expect(find.text('Waiting on them'), findsOneWidget);
    expect(find.text('They promised to do or send something.'), findsOneWidget);
    expect(find.text('I owe them'), findsNothing);

    await tester.tap(find.text('Track'));
    await tester.pumpAndSettle();

    expect(h.result, (kind: CommitmentKind.needsAction, due: CommitmentDue.thisWeek));
    expect(find.text('Track this message'), findsNothing);
  });

  testWidgets('a sent message offers "I owe them" (default) and "waiting on '
      'them", and the picks are returned', (tester) async {
    final h = await pump(tester, outgoing: true);

    expect(find.text('I owe them'), findsOneWidget);
    expect(find.text('Waiting on them'), findsOneWidget);
    expect(find.text('I asked them for something.'), findsOneWidget);
    expect(find.text('Needs my action'), findsNothing);

    await tester.tap(find.text('Waiting on them'));
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Track'));
    await tester.pumpAndSettle();

    expect(h.result, (kind: CommitmentKind.theyOweMe, due: CommitmentDue.today));
  });

  testWidgets('cancel returns nothing', (tester) async {
    final h = await pump(tester, outgoing: false);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.opened, isTrue);
    expect(h.result, isNull);
  });

  test('section titles match the pane', () {
    expect(commitmentSectionTitle(CommitmentKind.iOwe), 'You owe');
    expect(commitmentSectionTitle(CommitmentKind.theyOweMe), 'Waiting on');
    expect(commitmentSectionTitle(CommitmentKind.needsAction), 'Needs a decision');
  });
}

class _Harness {
  bool opened = false;
  TrackCommitmentChoice? result;
}
