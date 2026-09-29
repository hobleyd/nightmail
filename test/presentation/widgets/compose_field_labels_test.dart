import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/local_attachment.dart';
import 'package:nightmail/domain/repositories/contact_cache_repository.dart';
import 'package:nightmail/domain/repositories/directory_contacts_repository.dart';
import 'package:nightmail/domain/repositories/email_repository.dart';
import 'package:nightmail/domain/repositories/sender_repository.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/domain/usecases/ai/compose_reply.dart';
import 'package:nightmail/domain/usecases/delete_server_draft.dart';
import 'package:nightmail/domain/usecases/save_server_draft.dart';
import 'package:nightmail/domain/usecases/search_contacts.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/usecases/send_email.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/ai/ai_compose_cubit.dart';
import 'package:nightmail/presentation/blocs/compose/compose_bloc.dart';
import 'package:nightmail/presentation/widgets/compose_dialog.dart';

// ---------------------------------------------------------------------------
// Fakes — the least the form needs to mount.
// ---------------------------------------------------------------------------

class _FakeEmailRepository extends Fake implements EmailRepository {
  @override
  Future<Either<Failure, String>> createServerDraft({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    List<String> bccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async =>
      const Right('draft-1');

  @override
  Future<Either<Failure, String>> updateServerDraft({
    required String draftId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    List<String> bccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async =>
      Right(draftId);

  @override
  Future<Either<Failure, Unit>> deleteServerDraft(
          {required String draftId}) async =>
      const Right(unit);
}

class _FakeSystemContacts extends Fake implements SystemContactsRepository {
  @override
  Future<void> warmUp() async {}

  @override
  Future<List<ContactSuggestion>> search(String query) async => const [];
}

class _FakeSenderRepository extends Fake implements SenderRepository {}

class _FakeContactCacheRepository extends Fake
    implements ContactCacheRepository {}

class _FakeDirectoryContacts extends Fake
    implements DirectoryContactsRepository {}

class _FakeComposeReply extends Fake implements ComposeReply {}

// ---------------------------------------------------------------------------

/// Regression: the label column beside each compose field was a fixed 52px,
/// which fits "Subject" at 12px only in the desktop fonts at text scale 1.0.
/// On a phone with a larger system text size the label wrapped to
/// "Subje / ct". (The test font is wider still — every glyph is a square — so
/// a fixed column of any plausible width wraps here, which is what makes the
/// measured column testable.)
///
/// And the footer: one Row of format picker, Draft saved, AI, Cancel and Send
/// overflowed a phone's width, with Send half off the right edge.
void main() {
  setUp(() {
    final repository = _FakeEmailRepository();
    sl.registerSingleton<SystemContactsRepository>(_FakeSystemContacts());
    sl.registerSingleton<SearchContacts>(SearchContacts(
      senderRepository: _FakeSenderRepository(),
      contactCacheRepository: _FakeContactCacheRepository(),
      systemContactsRepository: _FakeSystemContacts(),
      directoryContactsRepository: _FakeDirectoryContacts(),
    ));
    sl.registerSingleton<SaveServerDraft>(SaveServerDraft(repository));
    sl.registerSingleton<DeleteServerDraft>(DeleteServerDraft(repository));
    sl.registerFactory<AiComposeCubit>(
        () => AiComposeCubit(composeReply: _FakeComposeReply()));
  });

  tearDown(() async {
    await sl.reset();
  });

  /// A plain-text compose form (no webview) at a phone's width, with the
  /// system text size turned up.
  Future<void> pumpForm(WidgetTester tester,
      {required double textScale,
      List<Account> accounts = const [],
      Email? draftEmail}) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: BlocProvider(
        create: (_) => ComposeBloc(sendEmail: SendEmail(_FakeEmailRepository())),
        child: Scaffold(
          body: ComposeForm(
            mode: ComposeMode.newEmail,
            onClose: () {},
            fromAddress: 'me@example.com',
            accountId: 'acct-1',
            accounts: accounts,
            draftEmail: draftEmail,
            scrollable: true,
            defaultComposeFormat: EmailBodyType.text,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// Opens the collapsed Bcc row through the Cc label's expander.
  Future<void> showBcc(WidgetTester tester) async {
    await tester.tap(find.text('Cc'));
    await tester.pump();
  }

  /// The label, as opposed to the field's hint, which says "Subject" too.
  RenderParagraph subjectLabel(WidgetTester tester) => tester
      .renderObjectList<RenderParagraph>(find.text('Subject'))
      .reduce((a, b) => a.constraints.maxWidth < b.constraints.maxWidth ? a : b);

  testWidgets('the Subject label stays on one line at a larger text size',
      (tester) async {
    await pumpForm(tester, textScale: 1.3);

    final label = subjectLabel(tester);
    // One line of 12px text at 1.3× is under 20px tall; two would be 40.
    expect(label.size.height, lessThan(30));
    // And the column was widened for it rather than the text being clipped.
    expect(label.constraints.maxWidth, greaterThanOrEqualTo(label.size.width));
  });

  testWidgets('the footer fits a phone, with the actions on their own line',
      (tester) async {
    await pumpForm(tester, textScale: 1.3);

    // A Row that overflows throws during layout; the pump above would have
    // surfaced it here.
    expect(tester.takeException(), isNull);
    final send = tester.getRect(find.widgetWithText(FilledButton, 'Send'));
    expect(send.right, lessThanOrEqualTo(390));
    // Below the format picker, not beside it.
    expect(send.top,
        greaterThan(tester.getRect(find.byType(DropdownButton<EmailBodyType>)).bottom));
  });

  testWidgets('every field label shares the same column width',
      (tester) async {
    await pumpForm(tester, textScale: 1.3);
    await showBcc(tester);

    final widths = <double>{
      for (final label in ['From', 'To', 'Cc', 'Bcc'])
        tester.renderObject<RenderParagraph>(find.text(label)).constraints.maxWidth,
      subjectLabel(tester).constraints.maxWidth,
    };
    expect(widths, hasLength(1), reason: 'the fields must stay aligned');
  });

  /// Regression: the To/Cc labels sat a fixed 6px below their row's top while
  /// the hint text sat at the top of the row, so the two never shared a line;
  /// the Subject row, with a different inset, happened to. Every row now
  /// aligns on the text baseline, so the label and whatever is beside it —
  /// hint, chip, account name — read as one line.
  testWidgets('every field label sits on the same baseline as its field',
      (tester) async {
    await pumpForm(tester, textScale: 1.0);
    await showBcc(tester);

    double baselineOf(RenderParagraph paragraph) {
      final top = paragraph.localToGlobal(Offset.zero).dy;
      return top +
          paragraph.getDryBaseline(
              paragraph.constraints, TextBaseline.alphabetic)!;
    }

    RenderParagraph paragraph(String text) =>
        tester.renderObject<RenderParagraph>(find.text(text));

    const rows = {
      'From': 'me@example.com',
      'To': 'recipient@example.com',
      'Cc': 'cc@example.com',
      'Bcc': 'bcc@example.com',
    };
    for (final MapEntry(key: label, value: field) in rows.entries) {
      expect(baselineOf(paragraph(label)),
          moreOrLessEquals(baselineOf(paragraph(field)), epsilon: 0.5),
          reason: '$label label vs its field');
    }
    final subjectHint = tester
        .renderObjectList<RenderParagraph>(find.text('Subject'))
        .reduce((a, b) => a.constraints.maxWidth > b.constraints.maxWidth ? a : b);
    expect(baselineOf(subjectLabel(tester)),
        moreOrLessEquals(baselineOf(subjectHint), epsilon: 0.5),
        reason: 'Subject label vs its hint');
  });

  testWidgets('with several accounts the From label sits on the dropdown text',
      (tester) async {
    const accounts = [
      GmailAccount(id: 'acct-1', displayName: 'Alice', emailAddress: 'a@x.com'),
      GmailAccount(id: 'acct-2', displayName: 'Bob', emailAddress: 'b@x.com'),
    ];
    await pumpForm(tester, textScale: 1.0, accounts: accounts);

    double baselineOf(RenderParagraph paragraph) =>
        paragraph.localToGlobal(Offset.zero).dy +
        paragraph.getDryBaseline(
            paragraph.constraints, TextBaseline.alphabetic)!;

    final label = tester.renderObject<RenderParagraph>(find.text('From'));
    // The dropdown lays out every item in a stack and shows the selected one.
    final selected =
        tester.renderObject<RenderParagraph>(find.text('Alice <a@x.com>'));
    expect(baselineOf(label), moreOrLessEquals(baselineOf(selected), epsilon: 0.5));
  });

  group('the Bcc row', () {
    testWidgets('is collapsed until the expander on the Cc row opens it',
        (tester) async {
      await pumpForm(tester, textScale: 1.0);
      expect(find.text('Bcc'), findsNothing);
      expect(find.byTooltip('Show Bcc'), findsOneWidget);

      await showBcc(tester);
      expect(find.text('Bcc'), findsOneWidget);
      expect(find.byTooltip('Hide Bcc'), findsOneWidget);
      expect(find.byTooltip('Show Bcc'), findsNothing);

      await showBcc(tester);
      expect(find.text('Bcc'), findsNothing);
      expect(find.byTooltip('Show Bcc'), findsOneWidget);
    });

    testWidgets('starts open for a draft that already has Bcc recipients',
        (tester) async {
      await pumpForm(
        tester,
        textScale: 1.0,
        draftEmail: Email(
          id: 'd1',
          subject: 'Draft',
          from: const EmailAddress(address: 'me@example.com'),
          toRecipients: const [],
          ccRecipients: const [],
          bccRecipients: const [EmailAddress(address: 'hidden@example.com')],
          bodyPreview: '',
          body: '',
          bodyType: EmailBodyType.text,
          isRead: true,
          receivedDateTime: DateTime(2026, 9, 29),
          importance: EmailImportance.normal,
        ),
      );
      expect(find.text('Bcc'), findsOneWidget);
      expect(find.text('hidden@example.com'), findsOneWidget);

      // With recipients in it the row cannot be hidden from sight.
      await showBcc(tester);
      expect(find.text('Bcc'), findsOneWidget);
      expect(find.byTooltip('Hide Bcc'), findsOneWidget);
    });
  });
}
