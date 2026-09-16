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
import 'package:nightmail/domain/usecases/delete_folder.dart';
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

class _FakeDeleteFolder extends Fake implements DeleteFolder {
  _FakeDeleteFolder();

  /// Set to make the provider refuse the delete.
  Failure? failure;
  final calls = <String>[];

  @override
  Future<Either<Failure, Unit>> call(String folderId) async {
    calls.add(folderId);
    final f = failure;
    return f == null ? const Right(unit) : Left(f);
  }
}

class _FakeMoveFolder extends Fake implements MoveFolder {
  /// The folder's id after the move. Same id for Graph and a real Gmail
  /// label; a different one where the id is a path.
  String Function(MoveFolderParams)? idAfterMove;

  /// Set to make the provider refuse the move.
  Failure? failure;
  final calls = <MoveFolderParams>[];

  @override
  Future<Either<Failure, String>> call(MoveFolderParams params) async {
    calls.add(params);
    final f = failure;
    if (f != null) return Left(f);
    return Right(idAfterMove?.call(params) ?? params.folderId);
  }
}

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
  late _FakeMoveFolder moveFolder;
  late _FakeDeleteFolder deleteFolder;
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
    moveFolder = _FakeMoveFolder();
    deleteFolder = _FakeDeleteFolder();
  });

  tearDown(() async => sl.reset());

  /// Focused by a test that wants the panel to open its editor against a
  /// scope that already has a focused descendant.
  late FocusNode elsewhere;

  /// Pumps the panel with the folder list already loaded, and [expanded]
  /// folders open — the panel expands a folder itself when the user asks to
  /// add a child, so a test only needs this for a parent it wants open first.
  Future<void> pumpPanel(
    WidgetTester tester, {
    Set<String> expanded = const {},
    ValueChanged<EmailFolder>? onFolderSelected,
    String selectedFolderId = 'inbox-id',
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
      moveFolder: moveFolder,
      deleteFolder: deleteFolder,
      accountManager: _FakeAccountManager(),
      staleRetryDelays: const [],
    );
    addTearDown(() => unawaited(folderList.close()));
    elsewhere = FocusNode();
    addTearDown(elsewhere.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          // Stands in for the rest of the app: a focusable the panel shares a
          // FocusScope with. `autofocus` is ignored while anything else in the
          // scope holds focus, so an editor that focuses itself in an empty
          // harness can still open dead in the app.
          Focus(focusNode: elsewhere, child: const SizedBox(width: 1)),
          SizedBox(
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
              selectedFolderId: selectedFolderId,
              onFolderSelected: onFolderSelected ?? (_) {},
              onCalendarTapped: () {},
              onTasksTapped: () {},
              onAiTapped: () {},
              initialExpandedIds: expanded,
            ),
          ),
        ),
        ]),
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

  /// Whether [name]'s row is not just built but actually inside the list's
  /// viewport. `findsOneWidget` is not enough: ListView.builder's cache extent
  /// builds rows a little past the fold, so a row the user cannot see still
  /// matches a plain finder.
  bool rowIsOnScreen(WidgetTester tester, String name) {
    final row = find.text(name);
    if (row.evaluate().isEmpty) return false;
    final list = tester.getRect(find.byType(ListView));
    final rect = tester.getRect(row);
    return rect.top >= list.top && rect.bottom <= list.bottom;
  }

  Finder creatingRow(String name) => find.byTooltip('Creating $name…');
  Finder failedRow(String name, String reason) =>
      find.byTooltip("Couldn't create $name: $reason");

  group('FolderPanel — creating a folder', () {
    testWidgets('scrolls the new folder into view when it sorts off screen',
        (tester) async {
      // The list is taller than the panel, and a new folder sorts in among
      // its siblings rather than landing where the editor was — so the row
      // the user just asked for arrives off screen and the create reads as
      // having done nothing.
      serverFolders = [
        _folder('inbox-id', 'Inbox', childFolderCount: 40),
        for (var i = 1; i <= 40; i++)
          _folder('child-$i', 'Child ${i.toString().padLeft(2, '0')}',
              parentFolderId: 'inbox-id'),
      ];
      createFolder.answer = (_) async => Right(_folder(
            'server-id',
            'Aardvark',
            parentFolderId: 'inbox-id',
          ));
      await pumpPanel(tester, expanded: {'inbox-id'});

      // The editor opens below the last child, so the list is scrolled to the
      // bottom by the time the name is submitted; the folder itself sorts to
      // the top of the children, which is now well above the fold.
      await addFolder(tester, folderName: 'Inbox', name: 'Aardvark');
      await tester.pumpAndSettle();

      expect(rowIsOnScreen(tester, 'Aardvark'), isTrue);
    });

    testWidgets('opens the editor focused, even when it had to be scrolled to',
        (tester) async {
      serverFolders = [
        _folder('inbox-id', 'Inbox', childFolderCount: 40),
        for (var i = 1; i <= 40; i++)
          _folder('child-$i', 'Child ${i.toString().padLeft(2, '0')}',
              parentFolderId: 'inbox-id'),
      ];
      await pumpPanel(tester, expanded: {'inbox-id'});
      elsewhere.requestFocus();
      await tester.pump();

      await tester.tap(find.text('Inbox'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Folder'));
      await tester.pumpAndSettle();

      // `enterText` focuses the field itself, so every other test here would
      // pass on an editor the user has to click first.
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
        isTrue,
      );
    });

    testWidgets('the rename editor opens focused too', (tester) async {
      serverFolders = [
        _folder('inbox-id', 'Inbox'),
        _folder('projects-id', 'Projects'),
      ];
      await pumpPanel(tester);
      elsewhere.requestFocus();
      await tester.pump();

      await tester.tap(find.text('Projects'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename Folder'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
        isTrue,
      );
    });

    testWidgets('leaves the list where it is when the new row is already there',
        (tester) async {
      // `Scrollable.ensureVisible` scrolls whether or not it needs to, so
      // centring the new row unconditionally would jerk the list on the
      // common case: a folder appearing directly under the parent it was
      // added to, in plain sight.
      serverFolders = [
        _folder('inbox-id', 'Inbox'),
        for (var i = 1; i <= 40; i++) _folder('root-$i', 'Folder $i'),
      ];
      createFolder.answer = (params) async => Right(_folder(
            'server-id',
            params.displayName,
            parentFolderId: params.parentFolderId,
          ));
      await pumpPanel(tester);

      // Scrolled off both ends, and the parent taken from the lower part of
      // the viewport, so centring its new child really would move the list —
      // the offset holding still below is the visibility guard's doing and
      // not `ensureVisible`'s clamp against the top of the list.
      final controller =
          tester.widget<ListView>(find.byType(ListView)).controller!;
      controller.jumpTo(300);
      await tester.pumpAndSettle();
      final list = tester.getRect(find.byType(ListView));
      final parent = [for (var i = 1; i <= 40; i++) 'Folder $i'].firstWhere((n) {
        final row = find.text(n);
        if (row.evaluate().isEmpty) return false;
        final rect = tester.getRect(row);
        return rect.top > list.top + list.height * 0.6 &&
            rect.bottom <= list.bottom;
      });

      await addFolder(tester, folderName: parent, name: 'Receipts');
      await tester.pumpAndSettle();

      expect(rowIsOnScreen(tester, 'Receipts'), isTrue);
      expect(controller.offset, 300);
    });

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

  // -------------------------------------------------------------------------
  // Deleting a folder.
  // -------------------------------------------------------------------------

  group('FolderPanel — deleting a folder', () {
    setUp(() {
      serverFolders = [
        _folder('inbox-id', 'Inbox'),
        _folder('projects-id', 'Projects', childFolderCount: 1),
        _folder('sub-id', 'Datadog', parentFolderId: 'projects-id'),
      ];
    });

    Future<void> openMenu(WidgetTester tester, String folderName) async {
      await tester.tap(find.text(folderName), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
    }

    testWidgets('is offered on a user folder and not on a system one',
        (tester) async {
      await pumpPanel(tester);

      await openMenu(tester, 'Projects');
      expect(find.text('Delete Folder'), findsOneWidget);
      // The label change goes with it: "Rename" alone read as renaming
      // whatever was selected.
      expect(find.text('Rename Folder'), findsOneWidget);
      await tester.tap(find.text('Add Folder'));
      await tester.pumpAndSettle();

      // Every provider refuses to delete its own system folders, so the item
      // is not drawn rather than drawn and failing.
      await openMenu(tester, 'Inbox');
      expect(find.text('Delete Folder'), findsNothing);
    });

    testWidgets('asks first, names what goes with it, and deletes on confirm',
        (tester) async {
      await pumpPanel(tester, expanded: {'projects-id'});

      await openMenu(tester, 'Projects');
      await tester.tap(find.text('Delete Folder'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 folder inside it'), findsOneWidget);
      expect(deleteFolder.calls, isEmpty, reason: 'deleted before confirming');

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(deleteFolder.calls, isEmpty);
      expect(find.text('Projects'), findsOneWidget);

      // The reconcile fetch the delete fires is held open: the row has to go
      // without it, or this is no better than waiting for the tree.
      final slowFetch = Completer<Either<Failure, List<EmailFolder>>>();
      getMailFolders.answer = () => slowFetch.future;

      await openMenu(tester, 'Projects');
      await tester.tap(find.text('Delete Folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete Folder'));
      await tester.pumpAndSettle();

      expect(deleteFolder.calls, ['projects-id']);
      // Gone before the tree fetch, and its child with it.
      expect(find.text('Projects'), findsNothing);
      expect(find.text('Datadog'), findsNothing);

      slowFetch.complete(Right([_folder('inbox-id', 'Inbox')]));
      await tester.pumpAndSettle();
      expect(find.text('Projects'), findsNothing);
    });

    testWidgets('moves the selection off a folder that is going away',
        (tester) async {
      final selected = <String>[];
      // The child of the doomed folder is what is on screen: deleting the
      // parent takes it too, so the pane would be left on a folder the panel
      // no longer lists.
      await pumpPanel(
        tester,
        expanded: {'projects-id'},
        selectedFolderId: 'sub-id',
        onFolderSelected: (f) => selected.add(f.id),
      );

      await openMenu(tester, 'Projects');
      await tester.tap(find.text('Delete Folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete Folder'));
      await tester.pumpAndSettle();

      expect(selected, ['inbox-id']);
    });

    testWidgets('a refused delete leaves the folder on screen', (tester) async {
      deleteFolder.failure = const ServerFailure(message: 'nope');
      await pumpPanel(tester);

      await openMenu(tester, 'Projects');
      await tester.tap(find.text('Delete Folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete Folder'));
      await tester.pumpAndSettle();

      expect(deleteFolder.calls, ['projects-id']);
      expect(find.text('Projects'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // Dragging a folder onto another folder.
  //
  // Regression: nothing moved the row but the folder-tree fetch, and when it
  // landed the row *vanished* — a folder you have just dropped something onto
  // is a folder you have not expanded, so it arrived out of sight inside it.
  // -------------------------------------------------------------------------

  group('FolderPanel — moving a folder', () {
    setUp(() {
      serverFolders = [
        _folder('inbox-id', 'Inbox'),
        _folder('archive-id', 'Archive'),
        _folder('projects-id', 'Projects'),
      ];
    });

    /// Drags [from] onto [to]. The sideways nudge first is deliberate: a
    /// straight vertical drag is claimed by the enclosing ListView.
    Future<void> dragFolder(
      WidgetTester tester, {
      required String from,
      required String to,
    }) async {
      final gesture = await tester.startGesture(tester.getCenter(find.text(from)));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text(to)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('reparents the row into the folder it was dropped on, and '
        'opens it so the row is visible there', (tester) async {
      await pumpPanel(tester);
      final rootIndent = tester.getTopLeft(find.text('Projects')).dx;

      // The fetch is held open: the move has to be on screen without it.
      final slowFetch = Completer<Either<Failure, List<EmailFolder>>>();
      getMailFolders.answer = () => slowFetch.future;

      await dragFolder(tester, from: 'Projects', to: 'Archive');

      expect(moveFolder.calls.single.folderId, 'projects-id');
      expect(moveFolder.calls.single.newParentFolderId, 'archive-id');
      // Still on screen — and now indented under its new parent, which is
      // open. Both halves matter: the row used to be inside a collapsed
      // Archive, which is indistinguishable from gone.
      expect(find.text('Projects'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Projects')).dx,
          greaterThan(rootIndent));
      expect(tester.getTopLeft(find.text('Projects')).dy,
          greaterThan(tester.getTopLeft(find.text('Archive')).dy));
      // Its new parent draws an open disclosure arrow, so it can be closed
      // again — a parent still reporting no children could not be.
      expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);

      slowFetch.complete(Right([
        _folder('inbox-id', 'Inbox'),
        _folder('archive-id', 'Archive', childFolderCount: 1),
        _folder('projects-id', 'Projects', parentFolderId: 'archive-id'),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Projects'), findsOneWidget);
    });

    testWidgets('a fetch that still shows the old place does not undo it',
        (tester) async {
      await pumpPanel(tester);

      // serverFolders is left as it was: the provider has taken the move but
      // the list it answers with was built before it applied. A tree fetch
      // replaces the whole list, so this is the emit that used to move the
      // row back.
      await dragFolder(tester, from: 'Projects', to: 'Archive');

      expect(find.text('Projects'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Projects')).dx,
          greaterThan(tester.getTopLeft(find.text('Archive')).dx));
    });

    testWidgets('a failed move leaves the folder where it was',
        (tester) async {
      await pumpPanel(tester);
      final rootIndent = tester.getTopLeft(find.text('Projects')).dx;
      moveFolder.failure = const ServerFailure(message: 'nope');

      await dragFolder(tester, from: 'Projects', to: 'Archive');

      // Nothing is drawn ahead of the provider's answer, so there is nothing
      // to put back: the folder simply never moved.
      expect(moveFolder.calls, hasLength(1));
      expect(find.text('Projects'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Projects')).dx, rootIndent);
    });
  });

  // -------------------------------------------------------------------------
  // "Delete All" — offered only where it can work.
  //
  // Emptying the trash is a permanent delete, and Gmail's only one
  // (`messages.batchDelete`) is behind a scope the app does not ask for. A
  // menu item that reliably fails is worse than no menu item.
  // -------------------------------------------------------------------------

  group('Delete All', () {
    testWidgets('is withheld on a Gmail trash folder', (tester) async {
      serverFolders = [_folder('inbox-id', 'Inbox'), _folder('trash-id', 'Trash')];
      await pumpPanel(tester);

      await tester.tap(find.text('Trash'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Delete All'), findsNothing);
      // The rest of the menu is untouched — this withholds one item, it does
      // not make a trash folder inert.
      expect(find.text('Rename Folder'), findsOneWidget);
    });

    testWidgets('is offered on every other Gmail folder', (tester) async {
      serverFolders = [_folder('inbox-id', 'Inbox'), _folder('spam-id', 'Spam')];
      await pumpPanel(tester);

      await tester.tap(find.text('Spam'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Delete All'), findsOneWidget);
    });

    testWidgets('is offered on a trash folder elsewhere', (tester) async {
      // Graph and IMAP both permanently delete under the scopes already held.
      when(accountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [
          MicrosoftAccount(
            id: 'acct-2',
            displayName: 'Bob',
            emailAddress: 'b@example.com',
            tenantId: 'tenant',
          )
        ],
        activeIndex: 0,
      ));
      serverFolders = [
        _folder('inbox-id', 'Inbox'),
        _folder('trash-id', 'Deleted Items'),
      ];
      await pumpPanel(tester);

      await tester.tap(find.text('Deleted Items'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Delete All'), findsOneWidget);
    });
  });
}
