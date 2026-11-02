import 'dart:async';

import 'package:meta/meta.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/domain/usecases/get_raw_email_bytes.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/email_detail/email_detail_bloc.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_bloc.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_event.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_state.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_bloc.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_event.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_state.dart';
import 'package:nightmail/presentation/blocs/home/home_cubit.dart';
import 'package:nightmail/presentation/blocs/mail_poller/mail_poller_cubit.dart';
import 'package:nightmail/presentation/blocs/mail_poller/mail_poller_state.dart';
import 'package:nightmail/presentation/blocs/tasks/overdue_tasks_cubit.dart';
import 'package:nightmail/presentation/blocs/tasks/tasks_bloc.dart';
import 'package:nightmail/presentation/blocs/tasks/tasks_state.dart';
import 'package:nightmail/presentation/widgets/email_list_panel.dart';

import 'email_list_selection_actions_test.mocks.dart';

// ---------------------------------------------------------------------------
// EmailListPanel — what a selection's header offers, and what Forward and
// Move do with it.
//
// On a phone a long-press selection used to show Compose, which has nothing to
// do with the rows picked. It now trades Compose for Forward (the selection as
// .eml attachments) and Move (a folder picked from a sheet). Only that
// selection does: a message merely open, and a desktop selection, keep
// Compose.
// ---------------------------------------------------------------------------

const _account = GmailAccount(
  id: 'acct-1',
  displayName: 'Me',
  emailAddress: 'me@example.com',
);

const _pollerState =
    MailPollerState(accountsWithNewMail: {}, pollIntervalSeconds: 300);

const _inbox = EmailFolder(
  id: 'inbox',
  displayName: 'Inbox',
  totalItemCount: 3,
  unreadItemCount: 1,
);
const _archive = EmailFolder(
  id: 'archive',
  displayName: 'Archive',
  totalItemCount: 0,
  unreadItemCount: 0,
);

Email _email(
  String id,
  String subject, {
  String? conversationId,
  bool isRead = true,
  int minutesAgo = 0,
}) =>
    Email(
      id: id,
      subject: subject,
      from: const EmailAddress(address: 'ada@example.com', name: 'Ada'),
      toRecipients: const [EmailAddress(address: 'me@example.com')],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: isRead,
      receivedDateTime:
          DateTime(2026, 11, 3, 9).subtract(Duration(minutes: minutesAgo)),
      importance: EmailImportance.normal,
      parentFolderId: 'inbox',
      conversationId: conversationId,
    );

class _FakeAccountManager extends Fake implements AccountManager {
  @override
  Account? get activeAccount => _account;
}

/// Answers each fetch from [answer], recording the ids asked for.
class _FakeGetRawEmailBytes extends Fake implements GetRawEmailBytes {
  _FakeGetRawEmailBytes(this.answer);

  Future<Either<Failure, Uint8List>> Function(String id) answer;
  final asked = <String>[];

  @override
  Future<Either<Failure, Uint8List>> call(String emailId) {
    asked.add(emailId);
    return answer(emailId);
  }
}

/// The panel decides touch from the target platform, which the variant sets
/// and — unlike a tear-down — clears before the framework checks it was.
@isTest
void _onPhone(String description, WidgetTesterCallback body) => testWidgets(
    description, body,
    variant: TargetPlatformVariant.only(TargetPlatform.iOS));

@isTest
void _onMac(String description, WidgetTesterCallback body) => testWidgets(
    description, body,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS));

@GenerateNiceMocks([
  MockSpec<EmailListBloc>(),
  MockSpec<FolderListBloc>(),
  MockSpec<MailPollerCubit>(),
  MockSpec<TasksBloc>(),
  MockSpec<OverdueTasksCubit>(),
  MockSpec<EmailDetailBloc>(),
  MockSpec<HomeCubit>(),
])
void main() {
  late MockEmailListBloc emailList;
  late MockFolderListBloc folderList;
  late MockMailPollerCubit mailPoller;
  late MockTasksBloc tasks;
  late MockOverdueTasksCubit overdueTasks;
  late MockEmailDetailBloc emailDetail;
  late MockHomeCubit home;
  late _FakeGetRawEmailBytes getRaw;

  final single = _email('m1', 'Quarterly numbers', isRead: false);
  // A thread of two Inbox messages: its row is headed by t2, the newest.
  final threadOld =
      _email('t1', 'Offsite plans', conversationId: 'conv-1', minutesAgo: 30);
  final threadNew =
      _email('t2', 'Re: Offsite plans', conversationId: 'conv-1', minutesAgo: 5);
  final emails = [single, threadNew, threadOld];

  setUp(() {
    provideDummy<EmailListState>(const EmailListInitial());
    provideDummy<FolderListState>(const FolderListLoaded(folders: []));
    provideDummy<MailPollerState>(_pollerState);
    provideDummy<TasksState>(const TasksInitial());

    emailList = MockEmailListBloc();
    when(emailList.stream).thenAnswer((_) => const Stream.empty());
    when(emailList.state).thenReturn(EmailListLoaded(
      emails: emails,
      currentFolderId: 'inbox',
      currentFolderName: 'Inbox',
    ));

    folderList = MockFolderListBloc();
    when(folderList.stream).thenAnswer((_) => const Stream.empty());
    when(folderList.state)
        .thenReturn(const FolderListLoaded(folders: [_inbox, _archive]));

    mailPoller = MockMailPollerCubit();
    when(mailPoller.stream).thenAnswer((_) => const Stream.empty());
    when(mailPoller.state).thenReturn(_pollerState);

    tasks = MockTasksBloc();
    when(tasks.stream).thenAnswer((_) => const Stream.empty());
    when(tasks.state).thenReturn(const TasksInitial());

    overdueTasks = MockOverdueTasksCubit();
    when(overdueTasks.stream).thenAnswer((_) => const Stream.empty());
    when(overdueTasks.state).thenReturn(0);

    emailDetail = MockEmailDetailBloc();
    home = MockHomeCubit();

    sl.registerSingleton<AccountManager>(_FakeAccountManager());
    getRaw = _FakeGetRawEmailBytes(
      (_) async => throw StateError('a test must set the fetch answer'),
    );
    sl.registerSingleton<GetRawEmailBytes>(getRaw);
  });

  tearDown(() async => sl.reset());

  /// Pumps the panel as the test's platform variant draws it (see [_onPhone],
  /// [_onMac]) — it reads the platform once, in initState.
  Future<void> pumpPanel(
    WidgetTester tester, {
    String? selectedEmailId,
  }) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider<EmailListBloc>.value(value: emailList),
          BlocProvider<FolderListBloc>.value(value: folderList),
          BlocProvider<MailPollerCubit>.value(value: mailPoller),
          BlocProvider<TasksBloc>.value(value: tasks),
          BlocProvider<OverdueTasksCubit>.value(value: overdueTasks),
          BlocProvider<EmailDetailBloc>.value(value: emailDetail),
          BlocProvider<HomeCubit>.value(value: home),
        ],
        child: Scaffold(
          body: EmailListPanel(
            folderName: 'Inbox',
            folder: _inbox,
            selectedEmailId: selectedEmailId,
            onEmailSelected: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  final compose = find.byTooltip('Compose');
  final forward = find.byTooltip('Forward as attachment');
  final move = find.byTooltip('Move to folder');

  Future<void> longPress(WidgetTester tester, String subject) async {
    await tester.longPress(find.text(subject));
    await tester.pumpAndSettle();
  }

  group('the header', () {
    _onPhone('shows Compose, not Forward or Move, with nothing selected',
        (tester) async {
      await pumpPanel(tester);

      expect(compose, findsOneWidget);
      expect(forward, findsNothing);
      expect(move, findsNothing);
    });

    _onPhone('trades Compose for Forward and Move on a long-press selection',
        (tester) async {
      await pumpPanel(tester);

      await longPress(tester, 'Quarterly numbers');

      expect(compose, findsNothing);
      expect(forward, findsOneWidget);
      expect(move, findsOneWidget);
    });

    _onPhone('gives Compose back once the last row is deselected',
        (tester) async {
      await pumpPanel(tester);
      await longPress(tester, 'Quarterly numbers');

      await tester.tap(find.text('Quarterly numbers'));
      await tester.pumpAndSettle();

      expect(compose, findsOneWidget);
      expect(forward, findsNothing);
      expect(move, findsNothing);
    });

    _onPhone('keeps Compose while a message is merely open',
        (tester) async {
      // The header's own hasSelection is true here too — it covers the open
      // message for Delete and Junk — and must not be what swaps Compose out.
      await pumpPanel(tester, selectedEmailId: 'm1');

      expect(compose, findsOneWidget);
      expect(forward, findsNothing);
      expect(move, findsNothing);
      expect(find.byTooltip('Delete selected'), findsOneWidget);
    });

    _onMac('keeps Compose for a desktop selection', (tester) async {
      await pumpPanel(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.tap(find.text('Quarterly numbers'));
      await tester.tap(find.text('Re: Offsite plans'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Delete selected'), findsOneWidget,
          reason: 'the selection took');
      expect(compose, findsOneWidget);
      expect(forward, findsNothing);
      expect(move, findsNothing);
    });
  });

  group('Forward', () {
    _onPhone('fetches the selection, showing progress while it does',
        (tester) async {
      final gate = Completer<Either<Failure, Uint8List>>();
      getRaw.answer = (_) => gate.future;
      await pumpPanel(tester);
      await longPress(tester, 'Quarterly numbers');

      await tester.tap(forward);
      await tester.pump();

      expect(getRaw.asked, ['m1']);
      final button = tester.widget<IconButton>(
          find.ancestor(of: find.byType(CircularProgressIndicator), matching: find.byType(IconButton)));
      expect(button.onPressed, isNull,
          reason: 'a second tap must not start a second forward');

      // Finish on a failure: success would open compose, which on the test
      // host is the desktop sub-window.
      gate.complete(const Left(NetworkFailure(message: 'No connection')));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    _onPhone('a thread row forwards its anchor message only',
        (tester) async {
      getRaw.answer =
          (_) async => const Left(NetworkFailure(message: 'No connection'));
      await pumpPanel(tester);
      await longPress(tester, 'Re: Offsite plans');

      await tester.tap(forward);
      await tester.pumpAndSettle();

      expect(getRaw.asked, ['t2']);
    });

    _onPhone(
        'a failed fetch says so, opens nothing and keeps the selection',
        (tester) async {
      getRaw.answer = (id) async => id == 't2'
          ? const Left(NetworkFailure(message: 'No connection'))
          : Right(Uint8List.fromList([1]));
      await pumpPanel(tester);
      await longPress(tester, 'Quarterly numbers');
      await tester.tap(find.text('Re: Offsite plans'));
      await tester.pumpAndSettle();

      await tester.tap(forward);
      await tester.pumpAndSettle();

      expect(getRaw.asked, unorderedEquals(['m1', 't2']));
      expect(find.text("Couldn't attach the messages: No connection"),
          findsOneWidget);
      expect(forward, findsOneWidget,
          reason: 'the user can retry without picking the rows again');
    });
  });

  group('Move', () {
    Future<EmailListEmailsMoved> moveTo(
        WidgetTester tester, String folderName) async {
      await tester.tap(move);
      await tester.pumpAndSettle();
      await tester.tap(find.text(folderName));
      await tester.pumpAndSettle();
      return verify(emailList.add(captureThat(isA<EmailListEmailsMoved>())))
          .captured
          .single as EmailListEmailsMoved;
    }

    _onPhone('files a single message in the folder picked',
        (tester) async {
      await pumpPanel(tester);
      await longPress(tester, 'Quarterly numbers');

      final event = await moveTo(tester, 'Archive');

      expect(event.emailIds, ['m1']);
      expect(event.destinationFolderId, 'archive');
      expect(event.conversationId, isNull);
      expect(compose, findsOneWidget, reason: 'the selection is cleared');
    });

    _onPhone('moves a selected thread whole, not just its anchor',
        (tester) async {
      await pumpPanel(tester);
      await longPress(tester, 'Re: Offsite plans');

      final event = await moveTo(tester, 'Archive');

      expect(event.emailIds, unorderedEquals(['t1', 't2']));
      expect(event.conversationId, 'conv-1');
      expect(event.destinationFolderId, 'archive');
    });

    _onPhone('moves the folder counts with the mail', (tester) async {
      await pumpPanel(tester);
      await longPress(tester, 'Quarterly numbers');

      await moveTo(tester, 'Archive');

      final counts = verify(folderList
              .add(captureThat(isA<FolderListUnreadCountChanged>())))
          .captured
          .cast<FolderListUnreadCountChanged>();
      expect(
        counts.map((e) => (e.folderId, e.unreadCountDelta, e.totalCountDelta)),
        [('inbox', -1, -1), ('archive', 1, 1)],
      );
      verify(mailPoller.decrementUnreadCount()).called(1);
    });

    _onPhone('dismissing the sheet moves nothing', (tester) async {
      await pumpPanel(tester);
      await longPress(tester, 'Quarterly numbers');

      await tester.tap(move);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();

      verifyNever(emailList.add(argThat(isA<EmailListEmailsMoved>())));
      expect(forward, findsOneWidget, reason: 'the selection survives');
    });
  });
}
