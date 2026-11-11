import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
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
import 'package:nightmail/domain/usecases/send_email.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/ai/ai_compose_cubit.dart';
import 'package:nightmail/presentation/blocs/compose/compose_bloc.dart';
import 'package:nightmail/presentation/widgets/compose_body_builder.dart';
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

/// Settings > Hide signature on internal replies: a reply or reply-all
/// with anyone on the account's own domain among its recipients opens without
/// the signature; one addressed only outside keeps it.
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

  const me = GmailAccount(
    id: 'acct-1',
    displayName: 'HTW',
    emailAddress: 'me@htw.com.au',
  );
  const signature = '<p>SIGNATURE-MARK</p>';

  Email original({
    String from = 'boss@htw.com.au',
    List<String> cc = const [],
  }) =>
      Email(
        id: 'orig',
        subject: 'Plans',
        from: EmailAddress(address: from),
        toRecipients: const [EmailAddress(address: 'me@htw.com.au')],
        ccRecipients: [for (final a in cc) EmailAddress(address: a)],
        bodyPreview: '',
        body: 'Thoughts?',
        bodyType: EmailBodyType.text,
        isRead: true,
        receivedDateTime: DateTime.utc(2026, 11, 12, 8, 0),
        importance: EmailImportance.normal,
      );

  /// A plain-text form (no webview), so the body is a TextField.
  Future<void> pump(
    WidgetTester tester, {
    required ComposeMode mode,
    Email? originalEmail,
    bool hide = true,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider(
        create: (_) => ComposeBloc(sendEmail: SendEmail(_FakeEmailRepository())),
        child: Scaffold(
          body: ComposeForm(
            mode: mode,
            originalEmail: originalEmail,
            onClose: () {},
            fromAddress: 'David <me@htw.com.au>',
            accountId: me.id,
            accounts: const [me],
            scrollable: true,
            defaultComposeFormat: EmailBodyType.text,
            signatureHtml: signature,
            hideSignatureForInternalReplies: hide,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Finder signatureText() =>
      find.textContaining('SIGNATURE-MARK', skipOffstage: false);

  testWidgets('a reply to a colleague opens without the signature',
      (tester) async {
    await pump(tester, mode: ComposeMode.reply, originalEmail: original());
    expect(signatureText(), findsNothing);
  });

  testWidgets('a reply-all with only colleagues opens without it',
      (tester) async {
    await pump(tester,
        mode: ComposeMode.replyAll,
        originalEmail: original(cc: ['colleague@HTW.com.au']));
    expect(signatureText(), findsNothing);
  });

  testWidgets('one colleague among outside recipients still drops it',
      (tester) async {
    await pump(tester,
        mode: ComposeMode.replyAll,
        originalEmail: original(
            from: 'client@example.com',
            cc: ['colleague@htw.com.au', 'x@example.com']));
    expect(signatureText(), findsNothing);
  });

  testWidgets('a reply-all with only outside recipients keeps it',
      (tester) async {
    await pump(tester,
        mode: ComposeMode.replyAll,
        originalEmail:
            original(from: 'client@example.com', cc: ['x@example.com']));
    expect(signatureText(), findsOneWidget);
  });

  testWidgets('a reply to an outside sender keeps it', (tester) async {
    await pump(tester,
        mode: ComposeMode.reply,
        originalEmail: original(from: 'client@example.com'));
    expect(signatureText(), findsOneWidget);
  });

  testWidgets('with the setting off, an internal reply keeps it',
      (tester) async {
    await pump(tester,
        mode: ComposeMode.reply, originalEmail: original(), hide: false);
    expect(signatureText(), findsOneWidget);
  });

  testWidgets('a new message keeps it', (tester) async {
    await pump(tester, mode: ComposeMode.newEmail);
    expect(signatureText(), findsOneWidget);
  });

  Finder signatureButton() => find.widgetWithText(TextButton, 'Signature');

  String body(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).last).controller!.text;

  testWidgets('a held-back signature can be put back above the quote',
      (tester) async {
    await pump(tester, mode: ComposeMode.reply, originalEmail: original());
    // The body as typing at the top of the reply leaves it.
    final quote = ComposeBodyBuilder.buildInitialPlainBody(
        originalEmail: original(), draftEmail: null, mode: ComposeMode.reply);
    tester.widget<TextField>(find.byType(TextField).last).controller!.text =
        'Sounds good$quote';
    await tester.pump();

    await tester.tap(signatureButton());
    await tester.pump();

    expect(body(tester), 'Sounds good\n\nSIGNATURE-MARK$quote');
    expect(signatureButton(), findsNothing);
  });

  testWidgets('with the quote deleted, it goes at the end', (tester) async {
    await pump(tester, mode: ComposeMode.reply, originalEmail: original());
    tester.widget<TextField>(find.byType(TextField).last).controller!.text =
        'Just this';
    await tester.pump();

    await tester.tap(signatureButton());
    await tester.pump();

    expect(body(tester), 'Just this\n\nSIGNATURE-MARK');
  });

  testWidgets('no Signature button when nothing was held back',
      (tester) async {
    await pump(tester,
        mode: ComposeMode.reply,
        originalEmail: original(from: 'client@example.com'));
    expect(signatureButton(), findsNothing);
  });

  test('nobody on a personal Google or Microsoft domain is internal', () {
    expect(
        ComposeFormState.isInternalAddress('a@gmail.com', 'me@gmail.com'), isFalse);
    expect(
        ComposeFormState.isInternalAddress('a@outlook.com', 'me@Outlook.com'),
        isFalse);
    expect(
        ComposeFormState.isInternalAddress('a@hotmail.co.uk', 'me@hotmail.co.uk'),
        isFalse);
    expect(
        ComposeFormState.isInternalAddress(
            'Boss <boss@htw.com.au>', 'me@htw.com.au'),
        isTrue);
  });
}
