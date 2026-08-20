import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/core/usecases/usecase.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/domain/usecases/create_folder.dart';
import 'package:nightmail/domain/usecases/get_cached_folders.dart';
import 'package:nightmail/domain/usecases/get_mail_folders.dart';
import 'package:nightmail/domain/usecases/move_folder.dart';
import 'package:nightmail/domain/usecases/rename_folder.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/migration/account_migration_service.dart';
import 'package:nightmail/infrastructure/update/app_update_status.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/account/account_cubit.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_bloc.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_state.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_bloc.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_event.dart';
import 'package:nightmail/presentation/blocs/mail_poller/mail_poller_cubit.dart';
import 'package:nightmail/presentation/blocs/mail_poller/mail_poller_state.dart';
import 'package:nightmail/presentation/blocs/tasks/overdue_tasks_cubit.dart';
import 'package:nightmail/presentation/blocs/update/update_cubit.dart';
import 'package:nightmail/presentation/widgets/email_drag_data.dart';
import 'package:nightmail/presentation/widgets/folder_drag_data.dart';
import 'package:nightmail/presentation/widgets/folder_panel.dart';

import 'folder_panel_test.mocks.dart';

// ---------------------------------------------------------------------------
// FolderPanel — creating a folder, from the gesture that starts it to the row
// that comes back.
//
// Regression these exist for: the create was awaited *and* a whole folder-tree
// fetch was awaited before anything was drawn, so the name the user had just
// typed vanished and reappeared a beat later. The bloc tests cover the state
// transitions; only a rendered panel can show whether the row is on screen at
// each step, and whether a failed one is still reachable.
// ---------------------------------------------------------------------------

const _account = GmailAccount(
  id: 'acct-1',
  displayName: 'Alice',
  emailAddress: 'a@gmail.com',
);

const _emptyPollerState =
    MailPollerState(accountsWithNewMail: {}, pollIntervalSeconds: 300);

EmailFolder _folder(
  String id,
  String name, {
  String? parentFolderId,
  int childFolderCount = 0,
}) =>
    EmailFolder(
      id: id,
      displayName: name,
      totalItemCount: 0,
      unreadItemCount: 0,
      parentFolderId: parentFolderId,
      childFolderCount: childFolderCount,
    );

class _FakeAccountManager extends Fake implements AccountManager {
  @override
  Account? activeAccount = _account;
}

class _FakeGetMailFolders extends Fake implements GetMailFolders {
  _FakeGetMailFolders(this.answer);

  /// Swapped between calls so a test can make the reconcile fetch slow, or
  /// make it come back without the folder that was just created.
  Future<Either<Failure, List<EmailFolder>>> Function() answer;

  @override
  Future<Either<Failure, List<EmailFolder>>> call(NoParams params) => answer();
}

class _FakeGetCachedFolders extends Fake implements GetCachedFolders {
  @override
  Future<Either<Failure, List<EmailFolder>>> call(String accountId) async =>
      const Right([]);
}

class _FakeCreateFolder extends Fake implements CreateFolder {
  _FakeCreateFolder(this.answer);

  Future<Either<Failure, EmailFolder>> Function(CreateFolderParams) answer;
  final calls = <CreateFolderParams>[];

  @override
  Future<Either<Failure, EmailFolder>> call(CreateFolderParams params) {
    calls.add(params);
    return answer(params);
  }
}

class _FakeRenameFolder extends Fake implements RenameFolder {}

class _FakeMoveFolder extends Fake implements MoveFolder {}

@GenerateMocks([
  AccountCubit,
  MailPollerCubit,
  EmailListBloc,
  OverdueTasksCubit,
  UpdateCubit,
])
@GenerateNiceMocks([MockSpec<AccountMigrationService>()])
void main() {
  late MockAccountCubit accountCubit;
  late MockMailPollerCubit mailPoller;
  late MockEmailListBloc emailList;
  late MockOverdueTasksCubit overdueTasks;
  late MockUpdateCubit updateCubit;

  late _FakeGetMailFolders getMailFolders;
  late _FakeCreateFolder createFolder;
  late FolderListBloc folderList;

  /// The folders the server answers with, unless a test replaces [answer].
  var serverFolders = <EmailFolder>[];

  setUp(() {
    provideDummy<AccountState>(const AccountNoAccounts());
    provideDummy<MailPollerState>(_emptyPollerState);
    provideDummy<EmailListState>(const EmailListInitial());
    provideDummy<AppUpdateStatus>(const AppUpdateStatus());

    accountCubit = MockAccountCubit();
    when(accountCubit.stream).thenAnswer((_) => const Stream.empty());
    when(accountCubit.state).thenReturn(
      const AccountsLoaded(accounts: [_account], activeIndex: 0),
    );

    mailPoller = MockMailPollerCubit();
    when(mailPoller.stream).thenAnswer((_) => const Stream.empty());
    when(mailPoller.state).thenReturn(_emptyPollerState);

    // Every folder row subscribes to this in didChangeDependencies to shimmer
    // while its folder is being emptied.
    emailList = MockEmailListBloc();
    when(emailList.stream).thenAnswer((_) => const Stream.empty());
    when(emailList.state).thenReturn(const EmailListInitial());

    overdueTasks = MockOverdueTasksCubit();
    when(overdueTasks.stream).thenAnswer((_) => const Stream.empty());
    when(overdueTasks.state).thenReturn(0);

    updateCubit = MockUpdateCubit();
    when(updateCubit.stream).thenAnswer((_) => const Stream.empty());
    when(updateCubit.state).thenReturn(const AppUpdateStatus());

    // AccountMenu reads this once per account from build to label its
    // migration entry; a nice mock answers "no active job".
    sl.registerLazySingleton<AccountMigrationService>(
        () => MockAccountMigrationService());

    serverFolders = [_folder('inbox-id', 'Inbox')];
    getMailFolders = _FakeGetMailFolders(() async => Right(serverFolders));
    createFolder = _FakeCreateFolder(
      (_) async => throw StateError('a test must set the create answer'),
    );
  });

  tearDown(() async => sl.reset());

  /// Pumps the panel with the folder list already loaded, and [expanded]
  /// folders open — the panel expands a folder itself when the user asks to
  /// add a child, so a test only needs this for a parent it wants open first.
  Future<void> pumpPanel(
    WidgetTester tester, {
    Set<String> expanded = const {},
    ValueChanged<EmailFolder>? onFolderSelected,
  }) async {
    // Built inside the test body, not in setUp: a bloc's event stream is
    // created in whatever zone constructs it, and one made in setUp delivers
    // its events outside the widget tester's fake-async zone — the load event
    // is then never processed and the panel sits on its spinner forever.
    folderList = FolderListBloc(
      getMailFolders: getMailFolders,
      getCachedFolders: _FakeGetCachedFolders(),
      createFolder: createFolder,
      renameFolder: _FakeRenameFolder(),
      moveFolder: _FakeMoveFolder(),
      accountManager: _FakeAccountManager(),
      staleRetryDelays: const [],
    );
    addTearDown(() => unawaited(folderList.close()));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          height: 700,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<AccountCubit>.value(value: accountCubit),
              BlocProvider<MailPollerCubit>.value(value: mailPoller),
              BlocProvider<EmailListBloc>.value(value: emailList),
              BlocProvider<OverdueTasksCubit>.value(value: overdueTasks),
              BlocProvider<UpdateCubit>.value(value: updateCubit),
              BlocProvider<FolderListBloc>.value(value: folderList),
            ],
            child: FolderPanel(
              selectedFolderId: 'inbox-id',
              onFolderSelected: onFolderSelected ?? (_) {},
              onCalendarTapped: () {},
              onTasksTapped: () {},
              onAiTapped: () {},
              initialExpandedIds: expanded,
            ),
          ),
        ),
      ),
    ));
    folderList.add(const FolderListLoadRequested());
    await tester.pumpAndSettle();
  }

  /// Right-clicks [folderName], picks "Add Folder", types [name] and submits —
  /// the whole of what the user does.
  Future<void> addFolder(
    WidgetTester tester, {
    required String folderName,
    required String name,
  }) async {
    await tester.tap(find.text(folderName), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), name);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  Finder creatingRow(String name) => find.byTooltip('Creating $name…');
  Finder failedRow(String name, String reason) =>
      find.byTooltip("Couldn't create $name: $reason");

  group('FolderPanel — creating a folder', () {
    testWidgets('keeps the typed name on screen while the create is in flight',
        (tester) async {
      final create = Completer<Either<Failure, EmailFolder>>();
      createFolder.answer = (_) => create.future;
      await pumpPanel(tester);

      await addFolder(tester, folderName: 'Inbox', name: 'Receipts');

      // The editor is gone — this is the row that replaces it, and without it
      // the name would be off screen for the length of the round trip.
      expect(find.byType(TextField), findsNothing);
      expect(creatingRow('Receipts'), findsOneWidget);
      expect(
        find.descendant(
          of: creatingRow('Receipts'),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(createFolder.calls.single.parentFolderId, 'inbox-id');
      expect(createFolder.calls.single.displayName, 'Receipts');

      create.complete(Right(_folder(
        'server-id',
        'Receipts',
        parentFolderId: 'inbox-id',
      )));
      await tester.pumpAndSettle();
    });

    testWidgets('draws the real folder before the tree fetch comes back',
        (tester) async {
      createFolder.answer = (_) async => Right(_folder(
            'server-id',
            'Receipts',
            parentFolderId: 'inbox-id',
          ));
      await pumpPanel(tester);

      // The reconcile fetch the create fires is held open: the folder has to
      // be on screen without it, or this is no better than what it replaced.
      final slowFetch = Completer<Either<Failure, List<EmailFolder>>>();
      getMailFolders.answer = () => slowFetch.future;

      await addFolder(tester, folderName: 'Inbox', name: 'Receipts');
      await tester.pump();

      expect(creatingRow('Receipts'), findsNothing);
      expect(find.text('Receipts'), findsOneWidget);
      // A real row, not the pending one: it has the folder icon and no spinner.
      expect(find.byType(CircularProgressIndicator), findsNothing);

      slowFetch.complete(Right([
        _folder('inbox-id', 'Inbox', childFolderCount: 1),
        _folder('server-id', 'Receipts', parentFolderId: 'inbox-id'),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Receipts'), findsOneWidget);
    });

    testWidgets('a tree fetch that has not caught up leaves the folder alone',
        (tester) async {
      createFolder.answer = (_) async => Right(_folder(
            'server-id',
            'Receipts',
            parentFolderId: 'inbox-id',
          ));
      await pumpPanel(tester);

      // Graph propagation / Gmail's cached label list: the folder exists, but
      // the list built a moment later does not name it. A tree fetch replaces
      // the whole list, so this is the emit that used to delete it.
      await addFolder(tester, folderName: 'Inbox', name: 'Receipts');
      await tester.pumpAndSettle();

      expect(find.text('Receipts'), findsOneWidget);
    });

    testWidgets('a failed create keeps the name, the reason and a way out',
        (tester) async {
      createFolder.answer =
          (_) async => const Left(NetworkFailure(message: 'No network connection'));
      await pumpPanel(tester);

      await addFolder(tester, folderName: 'Inbox', name: 'Receipts');
      await tester.pumpAndSettle();

      expect(failedRow('Receipts', 'No network connection'), findsOneWidget);
      expect(find.byTooltip('Try again'), findsOneWidget);
      expect(find.byTooltip('Dismiss'), findsOneWidget);
      // Nothing was invented in the tree to go with it.
      expect(find.text('Receipts'), findsOneWidget);

      await tester.tap(find.byTooltip('Try again'));
      await tester.pumpAndSettle();
      expect(createFolder.calls, hasLength(2));
      expect(createFolder.calls.last.displayName, 'Receipts');

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('Receipts'), findsNothing);
    });

    testWidgets('a failed row survives its parent being collapsed',
        (tester) async {
      // Only its own two buttons clear a failed create, so a row that hides
      // behind a disclosure triangle is a stuck state: set in the bloc,
      // unreachable on screen, and surviving every reload by design.
      serverFolders = [
        _folder('inbox-id', 'Inbox', childFolderCount: 1),
        _folder('sub-id', 'Existing', parentFolderId: 'inbox-id'),
      ];
      createFolder.answer =
          (_) async => const Left(ServerFailure(message: 'Name in use'));
      await pumpPanel(tester, expanded: {'inbox-id'});

      await addFolder(tester, folderName: 'Inbox', name: 'Receipts');
      await tester.pumpAndSettle();
      expect(failedRow('Receipts', 'Name in use'), findsOneWidget);

      // Where it sits matters as well as that it is there: falling back to
      // drawing it at the root would move it away from the folder it belongs
      // under, so its indentation is pinned to the child depth it had while
      // the parent was open.
      final childIndent = tester.getTopLeft(find.text('Receipts')).dx;
      expect(
        childIndent,
        greaterThan(tester.getTopLeft(find.text('Inbox')).dx),
      );

      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Existing'), findsNothing);
      expect(failedRow('Receipts', 'Name in use'), findsOneWidget);
      expect(find.byTooltip('Dismiss'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Receipts')).dx, childIndent);
    });

    testWidgets('a failed row survives its parent disappearing altogether',
        (tester) async {
      createFolder.answer =
          (_) async => const Left(ServerFailure(message: 'Name in use'));
      await pumpPanel(tester);

      await addFolder(tester, folderName: 'Inbox', name: 'Receipts');
      await tester.pumpAndSettle();
      expect(failedRow('Receipts', 'Name in use'), findsOneWidget);

      // The parent is deleted from another client while the create was
      // failing. The row has nothing to hang under and is appended at the
      // root, because it is still the only route to its own buttons.
      serverFolders = [];
      folderList.add(const FolderListLoadRequested());
      await tester.pumpAndSettle();

      expect(find.text('Inbox'), findsNothing);
      expect(failedRow('Receipts', 'Name in use'), findsOneWidget);
    });

    testWidgets('the pending row is neither a drop target nor selectable',
        (tester) async {
      final create = Completer<Either<Failure, EmailFolder>>();
      createFolder.answer = (_) => create.future;
      final selected = <String>[];
      await pumpPanel(tester, onFolderSelected: (f) => selected.add(f.id));
      await addFolder(tester, folderName: 'Inbox', name: 'Receipts');

      // There is no server id behind this row yet, so there is nothing it
      // could correctly do — a stand-in id would be a valid move destination
      // as far as everything downstream could tell, and dropping mail on it
      // would enqueue a move to a folder the server has never heard of.
      //
      // The Inbox row is the control: the same two finders do match there, so
      // "findsNothing" below is the row's own doing and not a wrong finder.
      Finder inboxRow() => find.ancestor(
            of: find.text('Inbox'),
            matching: find.byType(DragTarget<EmailDragData>),
          );
      expect(inboxRow(), findsOneWidget);
      expect(
        find.descendant(
          of: creatingRow('Receipts'),
          matching: find.byType(DragTarget<EmailDragData>),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.text('Inbox'),
          matching: find.byType(DragTarget<FolderDragData>),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: creatingRow('Receipts'),
          matching: find.byType(DragTarget<FolderDragData>),
        ),
        findsNothing,
      );

      await tester.tap(find.text('Inbox'));
      await tester.pump();
      expect(selected, ['inbox-id']);

      await tester.tap(find.text('Receipts'));
      await tester.pump();
      expect(selected, ['inbox-id'], reason: 'the pending row selected itself');

      create.complete(Right(_folder(
        'server-id',
        'Receipts',
        parentFolderId: 'inbox-id',
      )));
      await tester.pumpAndSettle();

      // The moment it is real, it behaves like any other folder.
      await tester.tap(find.text('Receipts'));
      await tester.pump();
      expect(selected, ['inbox-id', 'server-id']);
    });
  });
}
