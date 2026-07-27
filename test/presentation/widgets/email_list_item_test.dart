import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/presentation/widgets/email_list_item.dart';
import 'package:nightmail/presentation/widgets/flag_icon_button.dart';

Email _email({
  EmailAddress from = const EmailAddress(address: 'sender@example.com', name: 'Ada'),
  List<EmailAddress> toRecipients = const [],
  String subject = 'Quarterly numbers',
  String bodyPreview = 'Here are the figures you asked for',
  bool isRead = true,
  bool hasAttachments = false,
}) =>
    Email(
      id: 'email-1',
      subject: subject,
      from: from,
      toRecipients: toRecipients,
      ccRecipients: const [],
      bodyPreview: bodyPreview,
      body: '',
      bodyType: EmailBodyType.text,
      isRead: isRead,
      receivedDateTime: DateTime(2026, 6, 10, 9),
      importance: EmailImportance.normal,
      hasAttachments: hasAttachments,
    );

void main() {
  late int taps;
  late int deletes;
  late List<DateTime?> flags;

  setUp(() {
    taps = 0;
    deletes = 0;
    flags = [];
  });

  Future<void> pumpItem(
    WidgetTester tester,
    Email email, {
    bool isSelected = false,
    bool isMultiSelected = false,
    bool showCheckbox = false,
    bool isDesktop = true,
    VoidCallback? onDoubleTap,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: EmailListItem(
            email: email,
            isSelected: isSelected,
            isMultiSelected: isMultiSelected,
            showCheckbox: showCheckbox,
            isDesktop: isDesktop,
            onTap: () => taps++,
            onDelete: () => deletes++,
            onFlag: flags.add,
            onDoubleTap: onDoubleTap,
          ),
        ),
      ),
    ));
  }

  TextStyle styleOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!;

  group('EmailListItem — sender label', () {
    testWidgets('shows the sender display name', (tester) async {
      await pumpItem(tester, _email());

      expect(find.text('Ada'), findsOneWidget);
    });

    testWidgets('falls back to the address when the sender has no name',
        (tester) async {
      await pumpItem(
        tester,
        _email(from: const EmailAddress(address: 'sender@example.com')),
      );

      expect(find.text('sender@example.com'), findsOneWidget);
    });

    testWidgets('shows recipients instead when there is no sender',
        (tester) async {
      // Unsent drafts come back from Graph with an empty from address, and a
      // Drafts list of blank rows is useless.
      await pumpItem(
        tester,
        _email(
          from: const EmailAddress(address: ''),
          toRecipients: const [EmailAddress(address: 'bob@example.com', name: 'Bob')],
        ),
      );

      expect(find.text('To: Bob'), findsOneWidget);
    });

    testWidgets('lists at most two recipients, then elides', (tester) async {
      await pumpItem(
        tester,
        _email(
          from: const EmailAddress(address: ''),
          toRecipients: const [
            EmailAddress(address: 'a@example.com', name: 'Ann'),
            EmailAddress(address: 'b@example.com', name: 'Bob'),
            EmailAddress(address: 'c@example.com', name: 'Cat'),
          ],
        ),
      );

      expect(find.text('To: Ann, Bob…'), findsOneWidget);
    });

    testWidgets('names exactly two recipients without eliding', (tester) async {
      await pumpItem(
        tester,
        _email(
          from: const EmailAddress(address: ''),
          toRecipients: const [
            EmailAddress(address: 'a@example.com', name: 'Ann'),
            EmailAddress(address: 'b@example.com', name: 'Bob'),
          ],
        ),
      );

      expect(find.text('To: Ann, Bob'), findsOneWidget);
    });

    testWidgets('renders blank when there is neither sender nor recipient',
        (tester) async {
      await pumpItem(tester, _email(from: const EmailAddress(address: '')));

      expect(find.text(''), findsOneWidget);
    });
  });

  group('EmailListItem — unread emphasis', () {
    testWidgets('bolds the sender and subject when unread', (tester) async {
      await pumpItem(tester, _email(isRead: false));

      expect(styleOf(tester, 'Ada').fontWeight, FontWeight.w600);
      expect(styleOf(tester, 'Quarterly numbers').fontWeight, FontWeight.w500);
    });

    testWidgets('leaves them at normal weight when read', (tester) async {
      await pumpItem(tester, _email());

      expect(styleOf(tester, 'Ada').fontWeight, FontWeight.w400);
      expect(styleOf(tester, 'Quarterly numbers').fontWeight, FontWeight.w400);
    });

    testWidgets('shows the unread dot only when unread', (tester) async {
      await pumpItem(tester, _email(isRead: false));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1.0,
      );

      await pumpItem(tester, _email());
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0.0,
      );
    });
  });

  group('EmailListItem — content', () {
    testWidgets('shows the subject and preview', (tester) async {
      await pumpItem(tester, _email());

      expect(find.text('Quarterly numbers'), findsOneWidget);
      expect(find.text('Here are the figures you asked for'), findsOneWidget);
    });

    testWidgets('shows a paperclip only when there are attachments',
        (tester) async {
      await pumpItem(tester, _email());
      expect(find.byIcon(Icons.attach_file_rounded), findsNothing);

      await pumpItem(tester, _email(hasAttachments: true));
      expect(find.byIcon(Icons.attach_file_rounded), findsOneWidget);
    });
  });

  group('EmailListItem — selection affordances', () {
    testWidgets('hides the checkbox unless asked for', (tester) async {
      await pumpItem(tester, _email());

      expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    });

    testWidgets('shows an empty checkbox when not multi-selected',
        (tester) async {
      await pumpItem(tester, _email(), showCheckbox: true);

      expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsOneWidget);
    });

    testWidgets('shows a ticked checkbox when multi-selected', (tester) async {
      await pumpItem(tester, _email(),
          showCheckbox: true, isMultiSelected: true);

      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });
  });

  group('EmailListItem — callbacks', () {
    testWidgets('reports a tap', (tester) async {
      await pumpItem(tester, _email());

      await tester.tap(find.text('Quarterly numbers'));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('reports a delete', (tester) async {
      await pumpItem(tester, _email());

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pump();

      expect(deletes, 1);
      expect(taps, 0, reason: 'the row must not also open');
    });

    testWidgets('flags with no due date on a plain flag click', (tester) async {
      await pumpItem(tester, _email());

      await tester.tap(find.byType(FlagIconButton));
      await tester.pump();

      expect(flags, [null]);
    });

    testWidgets('omits the row actions on mobile', (tester) async {
      await pumpItem(tester, _email(), isDesktop: false);

      expect(find.byType(FlagIconButton), findsNothing);
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    });
  });
}
