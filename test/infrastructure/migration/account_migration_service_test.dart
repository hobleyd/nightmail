import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/utils/special_folder_kind.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/migration_local_datasource.dart';
import 'package:nightmail/data/datasources/remote/email_remote_datasource.dart';
import 'package:nightmail/data/models/email_address_model.dart';
import 'package:nightmail/data/models/email_folder_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/migration/account_migration_service.dart';
import 'package:nightmail/infrastructure/network/connectivity_service.dart';
import 'package:nightmail/infrastructure/sync/imap_connection_gate.dart';

import 'account_migration_service_test.mocks.dart';

const _woodgateBeach = ImapAccount(
  id: 'woodgate-beach',
  displayName: 'Woodgate Beach',
  emailAddress: 'me@woodgatebeach.example',
  host: 'imap.woodgatebeach.example',
  port: 993,
  useSsl: true,
  smtpHost: 'smtp.woodgatebeach.example',
  smtpPort: 465,
  smtpUseSsl: true,
);

const _o365 = MicrosoftAccount(
  id: 'o365',
  displayName: 'O365',
  emailAddress: 'me@o365.example',
  tenantId: 'common',
);

const _gmail = GmailAccount(
  id: 'gmail',
  displayName: 'Gmail',
  emailAddress: 'me@gmail.example',
);

final _rawBytes = Uint8List.fromList('Subject: hi\r\n\r\nbody'.codeUnits);

EmailFolderModel _folder(String id, String name,
        {String? parentFolderId, int childFolderCount = 0, int totalItemCount = 1}) =>
    EmailFolderModel(
      id: id,
      displayName: name,
      totalItemCount: totalItemCount,
      unreadItemCount: 0,
      parentFolderId: parentFolderId,
      childFolderCount: childFolderCount,
    );

EmailModel _email(String id, {bool isRead = true}) => EmailModel(
      id: id,
      subject: 'Subject $id',
      from: const EmailAddressModel(address: 'sender@example.com'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: isRead,
      receivedDateTime: DateTime(2026, 1, 1),
      importance: EmailImportance.normal,
      parentFolderId: 'irrelevant',
    );

@GenerateNiceMocks([
  MockSpec<EmailRemoteDatasource>(),
  MockSpec<AccountManager>(),
  MockSpec<ConnectivityService>(),
])
void main() {
  late AppDatabase db;
  late MockAccountManager mockAccountManager;
  late MockConnectivityService mockConnectivityService;
  late MockEmailRemoteDatasource sourceDs;
  late MockEmailRemoteDatasource targetDs;
  late AccountMigrationService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    mockAccountManager = MockAccountManager();
    mockConnectivityService = MockConnectivityService();
    sourceDs = MockEmailRemoteDatasource();
    targetDs = MockEmailRemoteDatasource();

    when(mockConnectivityService.isOnline).thenAnswer((_) async => true);
    // Defensive default — a folder this test's stubs don't special-case as
    // an existing special folder still needs *some* answer from
    // createFolder, even if no test actually exercises the by-name path.
    when(targetDs.createFolder(
      parentFolderId: anyNamed('parentFolderId'),
      displayName: anyNamed('displayName'),
    )).thenAnswer((_) async => 'created-folder-id');

    service = AccountMigrationService(
      accountManager: mockAccountManager,
      localDatasource: db,
      imapConnectionGate: ImapConnectionGate(),
      connectivityService: mockConnectivityService,
    );
  });

  tearDown(() async => db.close());

  void wireAccounts(Account source, Account target,
      {required EmailRemoteDatasource sourceDatasource,
      required EmailRemoteDatasource targetDatasource}) {
    when(mockAccountManager.accounts).thenReturn([source, target]);
    when(mockAccountManager.buildEmailDatasourceForAccount(source))
        .thenReturn(sourceDatasource);
    when(mockAccountManager.buildEmailDatasourceForAccount(target))
        .thenReturn(targetDatasource);
  }

  /// The first getEmails call for this folder answers with [page]; every
  /// call after that answers empty, so the folder resolves in one page.
  void oneCleanPage(
      MockEmailRemoteDatasource ds, String folderId, List<EmailModel> page) {
    var served = false;
    when(ds.getEmails(
      folderId: folderId,
      top: anyNamed('top'),
      skip: anyNamed('skip'),
      orderBy: anyNamed('orderBy'),
    )).thenAnswer((_) async {
      if (served) return const <EmailModel>[];
      served = true;
      return page;
    });
  }

  test(
      'maps a special folder by kind, not name — IMAP Spam lands in O365 Junk',
      () async {
    when(sourceDs.getMailFolders()).thenAnswer((_) async => [
          _folder('INBOX', 'Inbox'),
          _folder('Spam', 'Spam'),
        ]);
    when(sourceDs.getSpecialFolderIds()).thenAnswer((_) async => {
          SpecialFolderKind.inbox: 'INBOX',
          SpecialFolderKind.junk: 'Spam',
        });
    when(targetDs.getMailFolders()).thenAnswer((_) async => [
          _folder('inbox-id', 'Inbox'),
          _folder('junk-id', 'Junk'),
        ]);
    when(targetDs.getSpecialFolderIds()).thenAnswer((_) async => {
          SpecialFolderKind.inbox: 'inbox-id',
          SpecialFolderKind.junk: 'junk-id',
        });

    final spamEmail = _email('spam-msg-1');
    oneCleanPage(sourceDs, 'INBOX', const []);
    oneCleanPage(sourceDs, 'Spam', [spamEmail]);

    when(sourceDs.getRawEmailBytes('spam-msg-1'))
        .thenAnswer((_) async => _rawBytes);
    when(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).thenAnswer((_) async => 'dest-msg-1');

    wireAccounts(_woodgateBeach, _o365,
        sourceDatasource: sourceDs, targetDatasource: targetDs);

    await service.startOrResume(_woodgateBeach.id, _o365.id);

    final captured = verify(targetDs.insertRawMessage(
      folderId: captureAnyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).captured;
    expect(captured, ['junk-id']);

    final job = await service.getJob(_woodgateBeach.id, _o365.id);
    expect(job?.status, MigrationJobStatus.completed);
  });

  test('a message already ledgered done is never re-copied on resume',
      () async {
    when(sourceDs.getMailFolders())
        .thenAnswer((_) async => [_folder('INBOX', 'Inbox')]);
    when(sourceDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'INBOX'});
    when(targetDs.getMailFolders())
        .thenAnswer((_) async => [_folder('inbox-id', 'Inbox')]);
    when(targetDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'inbox-id'});

    oneCleanPage(sourceDs, 'INBOX', [_email('already-done')]);

    wireAccounts(_woodgateBeach, _o365,
        sourceDatasource: sourceDs, targetDatasource: targetDs);

    final jobId = AccountMigrationService.jobIdFor(_woodgateBeach.id, _o365.id);
    await db.upsertJob(
      jobId: jobId,
      sourceAccountId: _woodgateBeach.id,
      targetAccountId: _o365.id,
      status: MigrationJobStatus.running,
    );
    await db.upsertLedgerRow(
      jobId: jobId,
      sourceFolderId: 'INBOX',
      sourceMessageId: 'already-done',
      status: MigrationMessageStatus.done,
      destFolderId: 'inbox-id',
      destMessageId: 'already-there',
    );

    await service.startOrResume(_woodgateBeach.id, _o365.id);

    verifyNever(sourceDs.getRawEmailBytes(any));
    verifyNever(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    ));
  });

  test(
      'a message that keeps failing is reported and does not block the '
      'next message in the folder', () async {
    when(sourceDs.getMailFolders())
        .thenAnswer((_) async => [_folder('INBOX', 'Inbox')]);
    when(sourceDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'INBOX'});
    when(targetDs.getMailFolders())
        .thenAnswer((_) async => [_folder('inbox-id', 'Inbox')]);
    when(targetDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'inbox-id'});

    final bad = _email('bad-msg');
    final good = _email('good-msg');
    oneCleanPage(sourceDs, 'INBOX', [bad, good]);

    // The failure point is the source fetch for 'bad-msg' specifically —
    // simpler to target deterministically than trying to distinguish
    // otherwise-identical insertRawMessage calls.
    when(sourceDs.getRawEmailBytes('bad-msg'))
        .thenThrow(const ServerException(message: 'boom'));
    when(sourceDs.getRawEmailBytes('good-msg'))
        .thenAnswer((_) async => _rawBytes);
    when(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).thenAnswer((_) async => 'dest-ok');

    wireAccounts(_woodgateBeach, _o365,
        sourceDatasource: sourceDs, targetDatasource: targetDs);

    await service.startOrResume(_woodgateBeach.id, _o365.id);

    final job = await service.getJob(_woodgateBeach.id, _o365.id);
    expect(job?.status, MigrationJobStatus.completed);

    final failures = await service.getFailures(_woodgateBeach.id, _o365.id);
    expect(failures.map((f) => f.sourceMessageId), ['bad-msg']);

    // The good message still made it through despite the bad one failing.
    verify(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).called(1);
  });

  test('a Gmail message under two labels is copied only once', () async {
    when(sourceDs.getMailFolders()).thenAnswer((_) async => [
          _folder('INBOX', 'Inbox'),
          _folder('Label_1', 'Projects'),
        ]);
    when(sourceDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'INBOX'});
    when(targetDs.getMailFolders()).thenAnswer((_) async => [
          _folder('inbox-id', 'Inbox'),
          _folder('projects-id', 'Projects'),
        ]);
    when(targetDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'inbox-id'});

    // Same message id shows up under both labels/folders.
    oneCleanPage(sourceDs, 'INBOX', [_email('shared-msg')]);
    oneCleanPage(sourceDs, 'Label_1', [_email('shared-msg')]);

    when(sourceDs.getRawEmailBytes('shared-msg'))
        .thenAnswer((_) async => _rawBytes);
    when(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).thenAnswer((_) async => 'dest-shared');

    wireAccounts(_gmail, _o365,
        sourceDatasource: sourceDs, targetDatasource: targetDs);

    await service.startOrResume(_gmail.id, _o365.id);

    verify(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).called(1);
  });

  test('the Drafts folder is skipped entirely', () async {
    when(sourceDs.getMailFolders()).thenAnswer((_) async => [
          _folder('INBOX', 'Inbox'),
          _folder('Drafts', 'Drafts'),
        ]);
    when(sourceDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'INBOX'});
    when(targetDs.getMailFolders())
        .thenAnswer((_) async => [_folder('inbox-id', 'Inbox')]);
    when(targetDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'inbox-id'});

    oneCleanPage(sourceDs, 'INBOX', const []);

    wireAccounts(_woodgateBeach, _o365,
        sourceDatasource: sourceDs, targetDatasource: targetDs);

    await service.startOrResume(_woodgateBeach.id, _o365.id);

    verifyNever(sourceDs.getEmails(
      folderId: 'Drafts',
      top: anyNamed('top'),
      skip: anyNamed('skip'),
      orderBy: anyNamed('orderBy'),
    ));
  });

  test(
      'a resumed folder pass always starts its first page at skip:0, never '
      "seeded from the ledger's resolved count", () async {
    // Regression: seeding the first call's skip from a resolved count breaks
    // two providers differently — IMAP ignores orderBy and returns
    // newest-first, so an ascending cursor assumption is backwards, and
    // Gmail's skip>0 only works via a page token stored on the *same*
    // datasource instance's prior skip:0 call, which a freshly-built resume
    // instance never has. Both fail silently rather than throwing, so this
    // is asserted directly on the skip value of the first call rather than
    // inferred from an error.
    when(sourceDs.getMailFolders())
        .thenAnswer((_) async => [_folder('INBOX', 'Inbox')]);
    when(sourceDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'INBOX'});
    when(targetDs.getMailFolders())
        .thenAnswer((_) async => [_folder('inbox-id', 'Inbox')]);
    when(targetDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'inbox-id'});

    oneCleanPage(sourceDs, 'INBOX', [_email('new-msg')]);

    when(sourceDs.getRawEmailBytes('new-msg'))
        .thenAnswer((_) async => _rawBytes);
    when(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).thenAnswer((_) async => 'dest-new');

    wireAccounts(_woodgateBeach, _o365,
        sourceDatasource: sourceDs, targetDatasource: targetDs);

    // A prior run already resolved one message in this folder — with a
    // resolved-count-seeded cursor this would start the next getEmails call
    // at skip:1, hiding 'new-msg' from a mock (or, on real Gmail, hanging
    // forever on a re-served first page).
    final jobId = AccountMigrationService.jobIdFor(_woodgateBeach.id, _o365.id);
    await db.upsertJob(
      jobId: jobId,
      sourceAccountId: _woodgateBeach.id,
      targetAccountId: _o365.id,
      status: MigrationJobStatus.running,
    );
    await db.upsertLedgerRow(
      jobId: jobId,
      sourceFolderId: 'INBOX',
      sourceMessageId: 'already-done-elsewhere',
      status: MigrationMessageStatus.done,
      destFolderId: 'inbox-id',
      destMessageId: 'already-there',
    );

    await service.startOrResume(_woodgateBeach.id, _o365.id);

    final skips = verify(sourceDs.getEmails(
      folderId: 'INBOX',
      top: anyNamed('top'),
      skip: captureAnyNamed('skip'),
      orderBy: anyNamed('orderBy'),
    )).captured;
    expect(skips.first, 0);
    verify(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).called(1);
  });

  test(
      'a folder pass terminates when the provider wraps back to page one '
      'instead of answering empty', () async {
    // Models Gmail's real getEmails behaviour, which oneCleanPage does not:
    // once its per-folder page token runs out, a further nonzero-skip call
    // re-serves page one rather than returning empty (gmail_datasource_impl
    // clears the token once nextPageToken is absent, and a skip>0 call with
    // no stored token drops the pageToken query param entirely). A folder
    // pass that only terminates on an empty page would loop on this forever.
    when(sourceDs.getMailFolders())
        .thenAnswer((_) async => [_folder('INBOX', 'Inbox')]);
    when(sourceDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'INBOX'});
    when(targetDs.getMailFolders())
        .thenAnswer((_) async => [_folder('inbox-id', 'Inbox')]);
    when(targetDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'inbox-id'});

    final pageA = [_email('msg-a')];
    final pageB = [_email('msg-b')];
    when(sourceDs.getEmails(
      folderId: 'INBOX',
      top: anyNamed('top'),
      skip: anyNamed('skip'),
      orderBy: anyNamed('orderBy'),
    )).thenAnswer((invocation) async {
      final skip = invocation.namedArguments[#skip] as int;
      if (skip == 0) return pageA;
      if (skip == pageA.length) return pageB;
      // Every call past the real last page re-serves page one instead of
      // answering empty — the behaviour a page-token-based provider falls
      // into once its token is gone, rather than a true "no more mail".
      return pageA;
    });

    when(sourceDs.getRawEmailBytes(any)).thenAnswer((_) async => _rawBytes);
    when(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).thenAnswer((_) async => 'dest-ok');

    wireAccounts(_gmail, _o365,
        sourceDatasource: sourceDs, targetDatasource: targetDs);

    await service.startOrResume(_gmail.id, _o365.id).timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          fail('folder pass never terminated on the wrapped page'),
    );

    final job = await service.getJob(_gmail.id, _o365.id);
    expect(job?.status, MigrationJobStatus.completed);

    verify(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).called(2);
  });

  test(
      'progress reports the current folder name and processed/total count '
      'as messages are copied', () async {
    when(sourceDs.getMailFolders()).thenAnswer((_) async => [
          _folder('INBOX', 'Inbox', totalItemCount: 5),
        ]);
    when(sourceDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'INBOX'});
    when(targetDs.getMailFolders())
        .thenAnswer((_) async => [_folder('inbox-id', 'Inbox')]);
    when(targetDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'inbox-id'});

    oneCleanPage(sourceDs, 'INBOX', [_email('msg-1'), _email('msg-2')]);

    when(sourceDs.getRawEmailBytes(any)).thenAnswer((_) async => _rawBytes);
    when(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).thenAnswer((_) async => 'dest-ok');

    wireAccounts(_woodgateBeach, _o365,
        sourceDatasource: sourceDs, targetDatasource: targetDs);

    expect(service.getProgress(_woodgateBeach.id, _o365.id), isNull);

    await service.startOrResume(_woodgateBeach.id, _o365.id);

    final progress = service.getProgress(_woodgateBeach.id, _o365.id);
    expect(progress?.folderName, 'Inbox');
    expect(progress?.processedCount, 2);
    expect(progress?.totalCount, 5);
  });

  test('progress omits the total when the provider reports none for the '
      'folder', () async {
    when(sourceDs.getMailFolders()).thenAnswer((_) async => [
          _folder('INBOX', 'Inbox', totalItemCount: 0),
        ]);
    when(sourceDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'INBOX'});
    when(targetDs.getMailFolders())
        .thenAnswer((_) async => [_folder('inbox-id', 'Inbox')]);
    when(targetDs.getSpecialFolderIds())
        .thenAnswer((_) async => {SpecialFolderKind.inbox: 'inbox-id'});

    oneCleanPage(sourceDs, 'INBOX', [_email('msg-1')]);

    when(sourceDs.getRawEmailBytes(any)).thenAnswer((_) async => _rawBytes);
    when(targetDs.insertRawMessage(
      folderId: anyNamed('folderId'),
      rawBytes: anyNamed('rawBytes'),
      receivedAt: anyNamed('receivedAt'),
      isRead: anyNamed('isRead'),
    )).thenAnswer((_) async => 'dest-ok');

    wireAccounts(_woodgateBeach, _o365,
        sourceDatasource: sourceDs, targetDatasource: targetDs);

    await service.startOrResume(_woodgateBeach.id, _o365.id);

    expect(service.getProgress(_woodgateBeach.id, _o365.id)?.totalCount, isNull);
  });

  test('an auth failure pauses the job rather than marking it failed',
      () async {
    when(sourceDs.getMailFolders())
        .thenThrow(const AuthException(message: 'token expired'));

    wireAccounts(_woodgateBeach, _o365,
        sourceDatasource: sourceDs, targetDatasource: targetDs);

    await service.startOrResume(_woodgateBeach.id, _o365.id);

    final job = await service.getJob(_woodgateBeach.id, _o365.id);
    expect(job?.status, MigrationJobStatus.paused);
    expect(job?.lastError, 'token expired');
  });
}
