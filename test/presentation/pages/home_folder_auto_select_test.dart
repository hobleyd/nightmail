import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/core/settings/app_settings.dart';
import 'package:nightmail/core/usecases/usecase.dart';
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
import 'package:nightmail/presentation/blocs/home/folder_auto_selection.dart';
import 'package:nightmail/presentation/blocs/home/home_cubit.dart';

// ---------------------------------------------------------------------------
// The Inbox is selected for the user, not by them: nothing in the UI ever asks
// for it. HomePage does it from a BlocListener, which cannot be reached without
// building the three-panel shell — so the rule itself lives in
// folderToAutoSelect(), and these tests drive it off a real FolderListBloc and
// a real HomeCubit in the same sequence HomePage does.
// ---------------------------------------------------------------------------

EmailFolder _folder(String id, String name) => EmailFolder(
      id: id,
      displayName: name,
      totalItemCount: 0,
      unreadItemCount: 0,
      isHidden: false,
      childFolderCount: 0,
    );

class _FakeAppSettings extends Fake implements AppSettings {}

class _FakeAccountManager extends Fake implements AccountManager {
  _FakeAccountManager(this.activeAccount);

  @override
  Account? activeAccount;
}

class _FakeGetMailFolders extends Fake implements GetMailFolders {
  _FakeGetMailFolders(this._folders);
  final List<EmailFolder> Function() _folders;

  @override
  Future<Either<Failure, List<EmailFolder>>> call(NoParams params) async =>
      Right(_folders());
}

class _FakeGetCachedFolders extends Fake implements GetCachedFolders {
  @override
  Future<Either<Failure, List<EmailFolder>>> call(String accountId) async =>
      const Right([]);
}

class _FakeCreateFolder extends Fake implements CreateFolder {}

class _FakeRenameFolder extends Fake implements RenameFolder {}

class _FakeMoveFolder extends Fake implements MoveFolder {}

void main() {
  // -------------------------------------------------------------------------
  // The rule in isolation.
  // -------------------------------------------------------------------------

  group('folderToAutoSelect', () {
    final folders = [
      _folder('archive-1', 'Archive'),
      _folder('inbox-1', 'Inbox'),
    ];

    EmailFolder? select({
      List<EmailFolder>? list,
      String? folderId,
      String? emailId,
      String? preferred,
    }) =>
        folderToAutoSelect(
          folders: list ?? folders,
          selectedFolderId: folderId,
          selectedEmailId: emailId,
          preferredFolderId: preferred,
        );

    test('picks the Inbox wherever it sits in the list', () {
      expect(select()?.id, 'inbox-1');
    });

    test('falls back to the first folder when there is no Inbox', () {
      expect(select(list: [_folder('a', 'Archive')])?.id, 'a');
    });

    test('leaves a folder the user has already chosen alone', () {
      expect(select(folderId: 'archive-1'), isNull);
    });

    // selectFolder() builds a new HomeState that zeroes selectedEmailId, so
    // auto-selecting here would unload an email opened by a notification tap.
    test('leaves an email opened from a notification alone', () {
      expect(select(emailId: 'msg-1'), isNull);
    });

    test('does nothing with an empty list rather than throwing', () {
      expect(select(list: const []), isNull);
    });

    test('prefers the folder the account was last left in', () {
      expect(select(preferred: 'archive-1')?.id, 'archive-1');
    });

    // The id was saved earlier in the session; the folder may have been
    // deleted or renamed away since, and the list is the authority.
    test('falls back to the Inbox when the saved folder is gone', () {
      expect(select(preferred: 'deleted-1')?.id, 'inbox-1');
    });

    test('a saved folder does not override a selection already made', () {
      expect(select(preferred: 'archive-1', folderId: 'inbox-1'), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // The rule against a real bloc, across an account switch.
  //
  // Regression: FolderListBloc kept the previous account's folders in state
  // across the switch and re-emitted them, so this rule fired on the old
  // mailbox's Inbox id and then stood down — leaving the folder panel with
  // nothing selected on the account the user had just switched to.
  // -------------------------------------------------------------------------

  group('auto-select across an account switch', () {
    const accountA = GmailAccount(
      id: 'acct-a',
      displayName: 'Personal',
      emailAddress: 'a@b.com',
    );
    const accountB = MicrosoftAccount(
      id: 'acct-b',
      displayName: 'Work',
      emailAddress: 'c@d.com',
      tenantId: 'tenant',
    );

    late _FakeAccountManager accounts;
    late FolderListBloc bloc;
    late HomeCubit home;
    late _HomeShell shell;

    /// The folders each account answers with. Keyed by account id so a test can
    /// take one away and watch the restore fall back.
    late Map<String, List<EmailFolder>> foldersByAccount;

    setUp(() {
      foldersByAccount = {
        for (final id in ['acct-a', 'acct-b'])
          id: [
            _folder('sent-$id', 'Sent Items'),
            _folder('inbox-$id', 'Inbox'),
            _folder('archive-$id', 'Archive'),
          ],
      };
      accounts = _FakeAccountManager(accountA);
      bloc = FolderListBloc(
        getMailFolders: _FakeGetMailFolders(
            () => foldersByAccount[accounts.activeAccount!.id]!),
        getCachedFolders: _FakeGetCachedFolders(),
        createFolder: _FakeCreateFolder(),
        renameFolder: _FakeRenameFolder(),
        moveFolder: _FakeMoveFolder(),
        accountManager: accounts,
      );
      addTearDown(bloc.close);

      home = HomeCubit(_FakeAppSettings());
      addTearDown(home.close);

      shell = _HomeShell(bloc: bloc, home: home, accounts: accounts);
      addTearDown(shell.dispose);
    });

    test('selects the Inbox of the account switched to', () async {
      await shell.loadFolders();
      expect(home.state.selectedFolderId, 'inbox-acct-a');

      await shell.switchTo(accountB);

      expect(home.state.selectedFolderId, 'inbox-acct-b');
      expect(shell.requestedFolderIds, ['inbox-acct-a', 'inbox-acct-b']);
    });

    // The restore used to run at the moment of the switch, where HomePage's own
    // listener cleared it a beat later — so it never took effect and every
    // switch back landed on the Inbox.
    test('returns to the folder the account was last left in', () async {
      await shell.loadFolders();
      home.selectFolder('archive-acct-a');

      await shell.switchTo(accountB);
      expect(home.state.selectedFolderId, 'inbox-acct-b');

      await shell.switchTo(accountA);
      expect(home.state.selectedFolderId, 'archive-acct-a');
    });

    test('falls back to the Inbox when the saved folder has since gone',
        () async {
      await shell.loadFolders();
      home.selectFolder('archive-acct-a');

      await shell.switchTo(accountB);
      foldersByAccount['acct-a']!.removeWhere((f) => f.id == 'archive-acct-a');
      await shell.switchTo(accountA);

      expect(home.state.selectedFolderId, 'inbox-acct-a');
    });

    // A notification tap switches accounts to show one specific email, and
    // defers selecting it until after the clear cascade. The folder list lands
    // in between, and auto-selecting then would zero selectedEmailId.
    test('leaves an email opened by a notification tap alone', () async {
      await shell.loadFolders();

      await shell.switchTo(accountB, thenOpenEmail: 'msg-1');
      expect(home.state.selectedEmailId, 'msg-1');

      // A later reload — the poller's, say — must not steal the pane either.
      await shell.loadFolders();
      expect(home.state.selectedEmailId, 'msg-1');
    });
  });
}

/// HomePage's two account-related `BlocListener`s, mirrored. They cannot be
/// reached without building the three-panel shell, so the parts worth testing
/// live in [folderToAutoSelect] and [HomeCubit] and this drives them in the
/// same order and on the same signals HomePage does.
class _HomeShell {
  _HomeShell({
    required this.bloc,
    required this.home,
    required this.accounts,
  }) {
    _accountShowing = accounts.activeAccount?.id;
    _sub = bloc.stream.listen(_onFolderListState);
  }

  final FolderListBloc bloc;
  final HomeCubit home;
  final _FakeAccountManager accounts;

  String? _accountShowing;
  late final StreamSubscription<FolderListState> _sub;

  /// The folder ids handed to EmailListBloc, in order.
  final requestedFolderIds = <String>[];

  void dispose() => _sub.cancel();

  void _onFolderListState(FolderListState state) {
    if (state is! FolderListLoaded) return;
    final target = folderToAutoSelect(
      folders: state.folders,
      selectedFolderId: home.state.selectedFolderId,
      selectedEmailId: home.state.selectedEmailId,
      preferredFolderId:
          home.savedFolderForAccount(accounts.activeAccount?.id ?? ''),
    );
    if (target == null) return;
    home.selectFolder(target.id);
    requestedFolderIds.add(target.id);
  }

  Future<void> loadFolders() async {
    bloc.add(const FolderListLoadRequested());
    await bloc.stream
        .firstWhere((s) => s is FolderListLoaded && !s.isRefreshing);
    await pumpEventQueue();
  }

  /// The AccountCubit listener: remember where the outgoing account was left,
  /// drop the selection, re-request the list. [thenOpenEmail] stands in for a
  /// notification tap, which selects its email once that cascade has run.
  Future<void> switchTo(Account account, {String? thenOpenEmail}) async {
    final leaving = home.state.selectedFolderId;
    if (_accountShowing != null && leaving != null && leaving.isNotEmpty) {
      home.rememberFolderForAccount(_accountShowing!, leaving);
    }
    _accountShowing = account.id;
    accounts.activeAccount = account;
    home.clearFolder();
    if (thenOpenEmail != null) home.selectEmail(thenOpenEmail);
    await loadFolders();
  }
}
