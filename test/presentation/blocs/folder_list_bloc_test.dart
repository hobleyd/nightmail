import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/domain/usecases/create_folder.dart';
import 'package:nightmail/domain/usecases/get_cached_folders.dart';
import 'package:nightmail/domain/usecases/get_mail_folders.dart';
import 'package:nightmail/domain/usecases/move_folder.dart';
import 'package:nightmail/domain/usecases/rename_folder.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_bloc.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_event.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_state.dart';

import 'folder_list_bloc_test.mocks.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

EmailFolder _inbox({required int unread, required int total}) => EmailFolder(
      id: 'inbox-id',
      displayName: 'Inbox',
      totalItemCount: total,
      unreadItemCount: unread,
      isHidden: false,
      childFolderCount: 0,
    );

EmailFolder _folder(String id, String name) => EmailFolder(
      id: id,
      displayName: name,
      totalItemCount: 0,
      unreadItemCount: 0,
      isHidden: false,
      childFolderCount: 0,
    );

class _FakeAccountManager extends Fake implements AccountManager {
  _FakeAccountManager([this.activeAccount = _defaultAccount]);

  static const _defaultAccount = GmailAccount(
    id: 'acct-1',
    displayName: 'Gmail',
    emailAddress: 'a@b.com',
  );

  @override
  Account? activeAccount;
}

int? _inboxUnread(FolderListState state) => state is FolderListLoaded
    ? state.folders
        .where((f) => f.displayName == 'Inbox')
        .firstOrNull
        ?.unreadItemCount
    : null;

@GenerateMocks([
  GetMailFolders,
  GetCachedFolders,
  CreateFolder,
  RenameFolder,
  MoveFolder,
])
void main() {
  late MockGetMailFolders mockGetMailFolders;
  late MockGetCachedFolders mockGetCachedFolders;

  setUpAll(() {
    provideDummy<Either<Failure, List<EmailFolder>>>(const Right([]));
  });

  setUp(() {
    mockGetMailFolders = MockGetMailFolders();
    mockGetCachedFolders = MockGetCachedFolders();
  });

  // Zero delays: the retry schedule itself is a product decision, and waiting
  // it out would put 23s into the suite.
  FolderListBloc makeBloc({
    List<Duration> retryDelays = const [Duration.zero, Duration.zero],
    AccountManager? accountManager,
  }) =>
      FolderListBloc(
        getMailFolders: mockGetMailFolders,
        getCachedFolders: mockGetCachedFolders,
        createFolder: MockCreateFolder(),
        renameFolder: MockRenameFolder(),
        moveFolder: MockMoveFolder(),
        accountManager: accountManager ?? _FakeAccountManager(),
        staleRetryDelays: retryDelays,
      );

  // ---------------------------------------------------------------------------
  // A cold-start fetch that fails behind a populated cache
  //
  // Regression: the failure is swallowed in favour of the cache, so an Inbox
  // that had 2 messages when the app was last closed reported 2 all morning —
  // nothing re-requested the folder list until the user pressed Refresh.
  // ---------------------------------------------------------------------------

  group('FolderListBloc — failed fetch over a populated cache', () {
    setUp(() {
      when(mockGetCachedFolders(any)).thenAnswer(
        (_) async => Right([_inbox(unread: 2, total: 2)]),
      );
    });

    test('retries and replaces the stale counts with the fresh ones', () async {
      var calls = 0;
      when(mockGetMailFolders(any)).thenAnswer((_) async {
        calls++;
        return calls == 1
            ? const Left(NetworkFailure(message: 'No network connection'))
            : Right([_inbox(unread: 27, total: 27)]);
      });

      final bloc = makeBloc();
      addTearDown(bloc.close);
      final states = <FolderListState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);

      bloc.add(const FolderListLoadRequested());
      await bloc.stream.firstWhere((s) => _inboxUnread(s) == 27);

      expect(calls, 2);
      // The stale count stays visible while the retry runs rather than being
      // replaced by a spinner or an error.
      expect(states.map(_inboxUnread), [2, 2, 27]);
      expect((states[1] as FolderListLoaded).isRefreshing, isFalse);
      expect((states.last as FolderListLoaded).isRefreshing, isFalse);
    });

    test('stops after the configured attempts and keeps the cached counts',
        () async {
      when(mockGetMailFolders(any)).thenAnswer(
        (_) async => const Left(NetworkFailure(message: 'No network')),
      );

      final bloc = makeBloc(
        retryDelays: const [Duration.zero, Duration.zero],
      );
      addTearDown(bloc.close);

      bloc.add(const FolderListLoadRequested());
      await pumpEventQueue(times: 50);

      // 1 initial attempt + one per delay.
      verify(mockGetMailFolders(any)).called(3);
      expect(_inboxUnread(bloc.state), 2);
      expect((bloc.state as FolderListLoaded).isRefreshing, isFalse);
    });

    test('an abandoned retry stops rather than firing later', () async {
      var calls = 0;
      when(mockGetMailFolders(any)).thenAnswer((_) async {
        calls++;
        return calls == 1
            ? const Left(NetworkFailure(message: 'No network'))
            : Right([_inbox(unread: 27, total: 27)]);
      });

      final bloc = makeBloc(retryDelays: const [Duration(milliseconds: 50)]);
      addTearDown(bloc.close);

      bloc.add(const FolderListLoadRequested());
      await bloc.stream.firstWhere(
        (s) => s is FolderListLoaded && !s.isRefreshing,
      );

      // A newer load lands before the pending retry's delay elapses and
      // fetches successfully; the superseded run must then give up instead of
      // fetching a third time.
      bloc.add(const FolderListLoadRequested());
      await bloc.stream.firstWhere((s) => _inboxUnread(s) == 27);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(calls, 2);
    });
  });

  // ---------------------------------------------------------------------------
  // Nothing cached — the error is on screen and offers its own retry, so the
  // silent one must not run.
  // ---------------------------------------------------------------------------

  test('a failed fetch with an empty cache errors without retrying', () async {
    when(mockGetCachedFolders(any)).thenAnswer((_) async => const Right([]));
    when(mockGetMailFolders(any)).thenAnswer(
      (_) async => const Left(AuthFailure(message: 'Session expired')),
    );

    final bloc = makeBloc();
    addTearDown(bloc.close);

    bloc.add(const FolderListLoadRequested());
    final state = await bloc.stream.firstWhere((s) => s is FolderListError)
        as FolderListError;

    expect(state.isAuthFailure, isTrue);
    await pumpEventQueue();
    verify(mockGetMailFolders(any)).called(1);
  });

  // ---------------------------------------------------------------------------
  // Overlapping loads. This event is added from several places that routinely
  // coincide at startup, and phase one used to re-read the cache over a
  // fresher result — walking the visible counts backwards.
  // ---------------------------------------------------------------------------

  test('a second load does not fall back to the cache over fresher counts',
      () async {
    when(mockGetCachedFolders(any)).thenAnswer(
      (_) async => Right([_inbox(unread: 2, total: 2)]),
    );
    when(mockGetMailFolders(any)).thenAnswer(
      (_) async => Right([_inbox(unread: 27, total: 27)]),
    );

    final bloc = makeBloc();
    addTearDown(bloc.close);

    bloc.add(const FolderListLoadRequested());
    await bloc.stream.firstWhere((s) => _inboxUnread(s) == 27);

    final states = <FolderListState>[];
    final sub = bloc.stream.listen(states.add);
    addTearDown(sub.cancel);
    clearInteractions(mockGetCachedFolders);

    bloc.add(const FolderListLoadRequested());
    await pumpEventQueue();

    expect(states.map(_inboxUnread), everyElement(27));
    expect((states.first as FolderListLoaded).isRefreshing, isTrue);
    verifyNever(mockGetCachedFolders(any));
  });

  // ---------------------------------------------------------------------------
  // An account switch. Nothing clears this bloc — the switch only re-requests —
  // so phase 1's prefer-state-over-cache shortcut used to re-emit the previous
  // mailbox's folders. HomePage auto-selects the Inbox of the first loaded list
  // it sees and then stands down, so it fastened onto an Inbox id the new
  // account does not have: nothing highlighted, and a message list loading a
  // dead id. Only two Gmail accounts hid it, both calling their inbox 'INBOX'.
  // ---------------------------------------------------------------------------

  group('FolderListBloc — the active account changes under the bloc', () {
    const accountA = GmailAccount(
      id: 'acct-a',
      displayName: 'Gmail',
      emailAddress: 'a@b.com',
    );
    const accountB = MicrosoftAccount(
      id: 'acct-b',
      displayName: 'Work',
      emailAddress: 'c@d.com',
      tenantId: 'tenant',
    );

    late _FakeAccountManager accounts;

    List<String>? loadedFolderIds(FolderListState state) =>
        state is FolderListLoaded
            ? state.folders.map((f) => f.id).toList()
            : null;

    setUp(() {
      accounts = _FakeAccountManager(accountA);
      when(mockGetCachedFolders(any)).thenAnswer((invocation) async {
        final id = invocation.positionalArguments.first as String;
        return Right([_folder('inbox-$id', 'Inbox')]);
      });
      when(mockGetMailFolders(any)).thenAnswer((_) async {
        final id = accounts.activeAccount!.id;
        return Right([
          _folder('inbox-$id', 'Inbox'),
          _folder('sent-$id', 'Sent Items'),
        ]);
      });
    });

    test('never re-emits the previous account\'s folders', () async {
      final bloc = makeBloc(accountManager: accounts);
      addTearDown(bloc.close);

      bloc.add(const FolderListLoadRequested());
      await bloc.stream
          .firstWhere((s) => s is FolderListLoaded && !s.isRefreshing);
      expect(loadedFolderIds(bloc.state), ['inbox-acct-a', 'sent-acct-a']);

      final states = <FolderListState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);

      accounts.activeAccount = accountB;
      bloc.add(const FolderListLoadRequested());
      await bloc.stream.firstWhere(
        (s) => s is FolderListLoaded && !s.isRefreshing,
      );

      // Every folder shown from the moment the switch is requested belongs to
      // the account switched to — the cached list first, then the fetched one.
      expect(
        states.map(loadedFolderIds).whereType<List<String>>(),
        everyElement(isNot(contains('inbox-acct-a'))),
      );
      expect(states.map(loadedFolderIds), [
        ['inbox-acct-b'],
        ['inbox-acct-b', 'sent-acct-b'],
      ]);
      verify(mockGetCachedFolders('acct-b')).called(1);
    });

    test('a reload on the same account still keeps its folders on screen',
        () async {
      final bloc = makeBloc(accountManager: accounts);
      addTearDown(bloc.close);

      bloc.add(const FolderListLoadRequested());
      await bloc.stream
          .firstWhere((s) => s is FolderListLoaded && !s.isRefreshing);
      clearInteractions(mockGetCachedFolders);

      // The guard is on the account, not on there having been a load: an
      // ordinary refresh must not start reading the cache again.
      bloc.add(const FolderListLoadRequested());
      await pumpEventQueue();

      expect(loadedFolderIds(bloc.state), ['inbox-acct-a', 'sent-acct-a']);
      verifyNever(mockGetCachedFolders(any));
    });
  });

  // ---------------------------------------------------------------------------
  // Overlapping loads resolving out of order. Cold start, the poller and the
  // refresh button all add this event, and it runs on the default concurrent
  // transformer.
  // ---------------------------------------------------------------------------

  test('a superseded run cannot overwrite a newer run\'s folders', () async {
    when(mockGetCachedFolders(any)).thenAnswer((_) async => const Right([]));
    final slow = Completer<Either<Failure, List<EmailFolder>>>();
    var calls = 0;
    when(mockGetMailFolders(any)).thenAnswer((_) async {
      calls++;
      // The first run's fetch resolves last, and with older counts.
      return calls == 1 ? slow.future : Right([_inbox(unread: 27, total: 27)]);
    });

    final bloc = makeBloc();
    addTearDown(bloc.close);

    bloc.add(const FolderListLoadRequested());
    await pumpEventQueue();
    bloc.add(const FolderListLoadRequested());
    await bloc.stream.firstWhere((s) => _inboxUnread(s) == 27);

    slow.complete(Right([_inbox(unread: 5, total: 5)]));
    await pumpEventQueue();

    expect(_inboxUnread(bloc.state), 27);
  });
}
