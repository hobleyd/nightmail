import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_bloc.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_event.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_state.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_bloc.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_event.dart';
import 'package:nightmail/presentation/blocs/folder_list/folder_list_state.dart';
import 'package:nightmail/presentation/blocs/tasks/overdue_tasks_cubit.dart';
import 'package:nightmail/presentation/blocs/tasks/tasks_bloc.dart';
import 'package:nightmail/presentation/blocs/tasks/tasks_event.dart';
import 'package:nightmail/presentation/blocs/tasks/tasks_state.dart';
import 'package:nightmail/presentation/widgets/email_list_item.dart';
import 'package:nightmail/presentation/widgets/email_list_panel.dart';

// ---------------------------------------------------------------------------
// EmailListPanel — selecting rows from the keyboard on the desktop: Up/Down
// opens, Shift extends from a fixed anchor, Cmd moves a cursor that Space
// picks with, and the list scrolls to follow. The range arithmetic itself is
// covered in email_list_selection_test.dart; these drive the real key and
// click handlers.
// ---------------------------------------------------------------------------

const _account = GmailAccount(
  id: 'acct-1',
  displayName: 'Alice',
  emailAddress: 'a@gmail.com',
);

Email _email(String id, int minute,
        {String? conversationId, String from = 'x@y.com'}) =>
    Email(
      id: id,
      subject: 'Subject $id',
      from: EmailAddress(address: from, name: 'X'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      // Newest first, so the list order is the order the ids are made in.
      receivedDateTime: DateTime(2026, 6, 1, 9).subtract(Duration(minutes: minute)),
      importance: EmailImportance.normal,
      conversationId: conversationId ?? 'conv-$id',
    );

class _FakeAccountManager extends Fake implements AccountManager {
  @override
  Account? activeAccount = _account;
}

class _FakeEmailListBloc extends Fake implements EmailListBloc {
  _FakeEmailListBloc(this.state);
  @override
  EmailListState state;
  final events = <EmailListEvent>[];
  @override
  Stream<EmailListState> get stream => const Stream.empty();
  @override
  bool get isClosed => false;
  @override
  void add(EmailListEvent event) => events.add(event);
  @override
  Future<void> close() async {}
}

class _FakeFolderListBloc extends Fake implements FolderListBloc {
  @override
  FolderListState get state => const FolderListInitial();
  @override
  Stream<FolderListState> get stream => const Stream.empty();
  @override
  bool get isClosed => false;
  @override
  void add(FolderListEvent event) {}
  @override
  Future<void> close() async {}
}

class _FakeTasksBloc extends Fake implements TasksBloc {
  @override
  TasksState get state => const TasksInitial();
  @override
  Stream<TasksState> get stream => const Stream.empty();
  @override
  bool get isClosed => false;
  @override
  void add(TasksBlocEvent event) {}
  @override
  Future<void> close() async {}
}

class _FakeOverdueTasksCubit extends Fake implements OverdueTasksCubit {
  @override
  int get state => 0;
  @override
  Stream<int> get stream => const Stream.empty();
  @override
  bool get isClosed => false;
  @override
  Future<void> close() async {}
}

/// Stands in for HomePage: holds the open message and hands it back down.
class _Host extends StatefulWidget {
  const _Host({required this.opened});
  final List<String> opened;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String? _selected;
  @override
  Widget build(BuildContext context) => EmailListPanel(
        folderName: 'Inbox',
        selectedEmailId: _selected,
        onEmailSelected: (e) {
          widget.opened.add(e.id);
          setState(() => _selected = e.id);
        },
      );
}

void main() {
  late List<String> opened;

  setUp(() {
    opened = [];
    sl.registerLazySingleton<AccountManager>(() => _FakeAccountManager());
  });

  tearDown(() async => sl.reset());

  Future<void> pumpList(WidgetTester tester, int count,
      {List<Email>? emails, Set<String> expanded = const {}}) async {
    emails ??= [for (var i = 0; i < count; i++) _email('m$i', i)];
    await tester.pumpWidget(MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider<EmailListBloc>.value(
              value: _FakeEmailListBloc(EmailListLoaded(
            emails: emails,
            expandedConversationIds: expanded,
          ))),
          BlocProvider<FolderListBloc>.value(value: _FakeFolderListBloc()),
          BlocProvider<TasksBloc>.value(value: _FakeTasksBloc()),
          BlocProvider<OverdueTasksCubit>.value(
              value: _FakeOverdueTasksCubit()),
        ],
        child: Scaffold(body: _Host(opened: opened)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Set<String> multiSelected(WidgetTester tester) => {
        for (final row
            in tester.widgetList<EmailListItem>(find.byType(EmailListItem)))
          if (row.isMultiSelected && !row.isDuplicate) row.email.id,
        // A thread header is private to the panel; read it by its fields.
        for (final dynamic header in tester.widgetList(find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_ConversationHeader')))
          if (header.isMultiSelected as bool)
            (header.anchorEmail as Email).id,
      };

  /// The row drawing the selection border.
  String bordered(WidgetTester tester) => tester
      .widgetList<EmailListItem>(find.byType(EmailListItem))
      .singleWhere((r) => r.isCursor ?? r.isSelected)
      .email
      .id;

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key,
      {LogicalKeyboardKey? modifier}) async {
    if (modifier != null) await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    if (modifier != null) await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  Future<void> click(WidgetTester tester, String id,
      {List<LogicalKeyboardKey> modifiers = const []}) async {
    for (final m in modifiers) {
      await tester.sendKeyDownEvent(m);
    }
    await tester.tap(find.text('Subject $id'));
    for (final m in modifiers) {
      await tester.sendKeyUpEvent(m);
    }
    await tester.pumpAndSettle();
  }

  const down = LogicalKeyboardKey.arrowDown;
  const up = LogicalKeyboardKey.arrowUp;
  const shift = LogicalKeyboardKey.shiftLeft;
  const cmd = LogicalKeyboardKey.metaLeft;

  // Cmd is the modifier on a Mac; everywhere else the same code reads Ctrl.
  void macTest(String description, WidgetTesterCallback body) => testWidgets(
      description, body,
      variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  group('on macOS', () {

    macTest('Up and Down open the neighbouring row', (tester) async {
      await pumpList(tester, 5);
      await click(tester, 'm1');
      await press(tester, down);
      await press(tester, down);
      await press(tester, up);
      expect(opened, ['m1', 'm2', 'm3', 'm2']);
      expect(multiSelected(tester), isEmpty);
    });

    macTest('Shift-Down extends from the open row without opening, and '
        'Shift-Up shrinks it back', (tester) async {
      await pumpList(tester, 5);
      await click(tester, 'm1');
      await press(tester, down, modifier: shift);
      await press(tester, down, modifier: shift);
      expect(multiSelected(tester), {'m1', 'm2', 'm3'});
      expect(bordered(tester), 'm3');
      await press(tester, up, modifier: shift);
      expect(multiSelected(tester), {'m1', 'm2'});
      // Past the anchor the range flips to the other side.
      await press(tester, up, modifier: shift);
      await press(tester, up, modifier: shift);
      expect(multiSelected(tester), {'m0', 'm1'});
      expect(opened, ['m1'], reason: 'extending must not open (mark read)');
    });

    macTest('Cmd-Down moves the cursor and Space picks the row',
        (tester) async {
      await pumpList(tester, 5);
      await click(tester, 'm0');
      await press(tester, down, modifier: cmd);
      await press(tester, down, modifier: cmd);
      expect(multiSelected(tester), {'m0'});
      expect(bordered(tester), 'm2');
      await press(tester, LogicalKeyboardKey.space);
      expect(multiSelected(tester), {'m0', 'm2'});
      // Space again takes it back out.
      await press(tester, LogicalKeyboardKey.space);
      expect(multiSelected(tester), {'m0'});
      expect(opened, ['m0']);
    });

    macTest('a Shift range after a Space pick keeps the earlier pick',
        (tester) async {
      await pumpList(tester, 6);
      await click(tester, 'm0');
      await press(tester, down, modifier: cmd);
      await press(tester, down, modifier: cmd);
      await press(tester, LogicalKeyboardKey.space);
      await press(tester, down, modifier: shift);
      await press(tester, down, modifier: shift);
      expect(multiSelected(tester), {'m0', 'm2', 'm3', 'm4'});
    });

    macTest('plain Down after a multi-selection opens the row after the '
        'cursor and drops the selection', (tester) async {
      await pumpList(tester, 6);
      await click(tester, 'm0');
      await press(tester, down, modifier: shift);
      await press(tester, down, modifier: shift);
      await press(tester, down);
      expect(opened, ['m0', 'm3']);
      expect(multiSelected(tester), isEmpty);
    });

    macTest('Escape drops a multi-selection', (tester) async {
      await pumpList(tester, 4);
      await click(tester, 'm0');
      await press(tester, down, modifier: shift);
      await press(tester, LogicalKeyboardKey.escape);
      expect(multiSelected(tester), isEmpty);
      expect(bordered(tester), 'm0');
    });

    macTest('Shift-click spans from a fixed anchor, replacing the last '
        'range', (tester) async {
      await pumpList(tester, 6);
      await click(tester, 'm1');
      await click(tester, 'm4', modifiers: [shift]);
      expect(multiSelected(tester), {'m1', 'm2', 'm3', 'm4'});
      await click(tester, 'm2', modifiers: [shift]);
      expect(multiSelected(tester), {'m1', 'm2'});
      await click(tester, 'm0', modifiers: [shift]);
      expect(multiSelected(tester), {'m0', 'm1'});
      expect(opened, ['m1']);
    });

    macTest('Cmd-click adds to the open row rather than starting afresh',
        (tester) async {
      await pumpList(tester, 4);
      await click(tester, 'm0');
      await click(tester, 'm2', modifiers: [cmd]);
      expect(multiSelected(tester), {'m0', 'm2'});
      // Cmd+Shift-click adds a range from the last pick.
      await click(tester, 'm3', modifiers: [cmd, shift]);
      expect(multiSelected(tester), {'m0', 'm2', 'm3'});
    });

    macTest('the list scrolls to keep the keyboard row in view',
        (tester) async {
      tester.view.physicalSize = const Size(800, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpList(tester, 40);
      await click(tester, 'm0');
      for (var i = 0; i < 15; i++) {
        await press(tester, down);
      }
      expect(opened.last, 'm15');
      final row = tester.getRect(find.text('Subject m15'));
      final list = tester.getRect(find.byType(ListView));
      expect(row.top, greaterThanOrEqualTo(list.top));
      expect(row.bottom, lessThanOrEqualTo(list.bottom));

      // And with Shift, where nothing is opened to scroll to.
      for (var i = 0; i < 10; i++) {
        await press(tester, down, modifier: shift);
      }
      final extended = tester.getRect(find.text('Subject m25'));
      expect(extended.bottom, lessThanOrEqualTo(list.bottom));
    });

    macTest('an expanded thread is walked row by row, skipping the echo of '
        "the header's own message", (tester) async {
      // The user's own reply is newest, so the thread is headed by t-old and
      // the expanded rows end with an echo of it.
      await pumpList(tester, 0, emails: [
        _email('t-mine', 0, conversationId: 't', from: _account.emailAddress),
        _email('t-old', 1, conversationId: 't'),
        _email('m2', 2),
      ], expanded: {'t'});
      expect(find.text('Subject t-old'), findsNWidgets(2));
      await tester.tap(find.text('Subject m2'));
      await tester.pumpAndSettle();
      await press(tester, up);
      await press(tester, up);
      expect(opened, ['m2', 't-mine', 't-old']);
      await press(tester, down, modifier: shift);
      await press(tester, down, modifier: shift);
      expect(multiSelected(tester), {'t-old', 't-mine', 'm2'});
    });
  });

  group('on Windows', () {
    void windowsTest(String description, WidgetTesterCallback body) =>
        testWidgets(description, body,
            variant: TargetPlatformVariant.only(TargetPlatform.windows));
    const ctrl = LogicalKeyboardKey.controlLeft;

    windowsTest('Ctrl-click adds to the open row', (tester) async {
      await pumpList(tester, 4);
      await click(tester, 'm0');
      await click(tester, 'm2', modifiers: [ctrl]);
      expect(multiSelected(tester), {'m0', 'm2'});
    });

    windowsTest('Ctrl-Down moves the cursor and Space picks the row',
        (tester) async {
      await pumpList(tester, 4);
      await click(tester, 'm0');
      await press(tester, down, modifier: ctrl);
      await press(tester, down, modifier: ctrl);
      await press(tester, LogicalKeyboardKey.space);
      expect(multiSelected(tester), {'m0', 'm2'});
      expect(opened, ['m0']);
    });

    windowsTest('Shift-Down extends the selection', (tester) async {
      await pumpList(tester, 4);
      await click(tester, 'm1');
      await press(tester, down, modifier: shift);
      expect(multiSelected(tester), {'m1', 'm2'});
    });
  });
}
