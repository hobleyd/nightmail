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
import 'package:nightmail/presentation/widgets/compose_dialog.dart';
import 'package:nightmail/presentation/widgets/recipient_input_field.dart';

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

/// Regression: a reply-all dropped the user from the recipients by comparing
/// each one to the single From address. An account recorded without an
/// address — every Gmail account added before 1.37.4 learned it on add, and a
/// phone's never re-signs in to learn it later — rendered that as
/// `Name <>`, which matches nobody, so the user kept turning up in their own
/// Reply All. Mail that had come to an alias did the same even with the
/// primary known. The form now strips every address the account answers for.
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
    aliases: ['alias@htw.com.au'],
  );

  /// Mail from the boss to the user (at an alias) and a colleague, copying
  /// the user again (primary, in another case) and a third person.
  final original = Email(
    id: 'orig',
    subject: 'Plans',
    from: const EmailAddress(address: 'boss@htw.com.au', name: 'Boss'),
    toRecipients: const [
      EmailAddress(address: 'alias@htw.com.au'),
      EmailAddress(address: 'colleague@htw.com.au'),
    ],
    ccRecipients: const [
      EmailAddress(address: 'Me@HTW.com.au'),
      EmailAddress(address: 'other@example.com'),
    ],
    bodyPreview: '',
    body: 'Thoughts?',
    bodyType: EmailBodyType.text,
    isRead: true,
    receivedDateTime: DateTime.utc(2026, 10, 9, 8, 0),
    importance: EmailImportance.normal,
  );

  /// A plain-text reply-all form (no webview) for [original].
  Future<void> pumpReplyAll(
    WidgetTester tester, {
    required String fromAddress,
    List<Account> accounts = const [],
    String? accountId,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider(
        create: (_) => ComposeBloc(sendEmail: SendEmail(_FakeEmailRepository())),
        child: Scaffold(
          body: ComposeForm(
            mode: ComposeMode.replyAll,
            originalEmail: original,
            onClose: () {},
            fromAddress: fromAddress,
            accountId: accountId,
            accounts: accounts,
            scrollable: true,
            defaultComposeFormat: EmailBodyType.text,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  List<String> recipients(WidgetTester tester, String label) => tester
      .widget<RecipientInputField>(find.byWidgetPredicate(
          (w) => w is RecipientInputField && w.label == label))
      .recipients;

  testWidgets('strips the primary and every alias the account answers for',
      (tester) async {
    await pumpReplyAll(
      tester,
      fromAddress: 'David <me@htw.com.au>',
      accounts: const [me],
      accountId: me.id,
    );

    expect(recipients(tester, 'To'),
        ['boss@htw.com.au', 'colleague@htw.com.au']);
    expect(recipients(tester, 'Cc'), ['other@example.com']);
  });

  testWidgets(
      'an account recorded without an address, whose From is "Name <>", '
      'is still stripped once its addresses are known', (tester) async {
    await pumpReplyAll(
      tester,
      fromAddress: 'David <>',
      accounts: const [me],
      accountId: me.id,
    );

    expect(recipients(tester, 'To'),
        ['boss@htw.com.au', 'colleague@htw.com.au']);
    expect(recipients(tester, 'Cc'), ['other@example.com']);
  });

  testWidgets('with no account to consult, the bare From address alone is me',
      (tester) async {
    await pumpReplyAll(tester, fromAddress: 'David <me@htw.com.au>');

    // The alias is unknown here, so it stays — the primary does not.
    expect(recipients(tester, 'To'), [
      'boss@htw.com.au',
      'alias@htw.com.au',
      'colleague@htw.com.au',
    ]);
    expect(recipients(tester, 'Cc'), ['other@example.com']);
  });
}
