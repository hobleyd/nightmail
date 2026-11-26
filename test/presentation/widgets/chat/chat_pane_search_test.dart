import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/repositories/chat_repository.dart';
import 'package:nightmail/domain/usecases/search_contacts.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/chat/chat_conversation_cubit.dart';
import 'package:nightmail/presentation/widgets/chat/chat_pane_picker.dart';

/// The pane's dropdown finds anyone or any chat by name: address-book
/// people only when a chat with them can exist, chats and channels from the
/// listing.
void main() {
  const account = MicrosoftAccount(
    id: 'acct',
    displayName: 'Me',
    emailAddress: 'me@contoso.com',
    tenantId: 'common',
  );
  late _Repo repo;

  setUp(() async {
    await sl.reset();
    repo = _Repo();
    sl.registerSingleton<ChatRepository>(repo);
    sl.registerSingleton<SearchContacts>(_Contacts());
  });

  tearDown(() => sl.reset());

  Future<({List<ChatPerson> people, List<ChatConversation> chats})> open(
      WidgetTester tester) async {
    final people = <ChatPerson>[];
    final chats = <ChatConversation>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatPanePicker(
          chatId: 'acct',
          account: account,
          people: const [ChatPerson(email: 'ann@contoso.com', name: 'Ann Lee')],
          chats: const [],
          selectedPerson:
              const ChatPerson(email: 'ann@contoso.com', name: 'Ann Lee'),
          selectedChat: null,
          onPerson: people.add,
          onChat: chats.add,
        ),
      ),
    ));
    await tester.tap(find.text('Ann Lee'));
    await tester.pumpAndSettle();
    return (people: people, chats: chats);
  }

  testWidgets('finds reachable people and matching channels', (tester) async {
    final picked = await open(tester);
    await tester.enterText(find.byType(TextField), 'bo');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(find.text('Bob Brown'), findsOneWidget);
    // Not reachable: an outsider with no chat.
    expect(find.text('Bo Outsider'), findsNothing);
    expect(find.text('#board'), findsOneWidget);
    expect(find.text('Ann Lee'), findsOneWidget); // the button
    expect(repo.reachableAsked, ['bob@contoso.com', 'bo@elsewhere.com']);

    await tester.tap(find.text('#board'));
    await tester.pumpAndSettle();
    expect(picked.chats.single.title, '#board');
  });

  testWidgets('the field has the caret when the menu opens, and keeps it '
      'under the mouse', (tester) async {
    await open(tester);
    bool focused() => tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode
        .hasPrimaryFocus;
    expect(focused(), isTrue);

    await tester.enterText(find.byType(TextField), 'bo');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('#board')));
    await tester.pumpAndSettle();
    expect(focused(), isTrue);
  });

  testWidgets('Enter picks the first match', (tester) async {
    final picked = await open(tester);
    await tester.enterText(find.byType(TextField), 'bob');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(picked.people.single.email, 'bob@contoso.com');
  });

  testWidgets('left and right move the cursor, not the menu focus',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.selection.baseOffset, 2);
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasPrimaryFocus,
        isTrue);
  });
}

class _Contacts extends Fake implements SearchContacts {
  @override
  Future<List<ContactSuggestion>> call({
    required String query,
    required String accountId,
    String? accountDomain,
  }) async =>
      const [
        ContactSuggestion(address: 'Bob@contoso.com', name: 'Bob Brown'),
        ContactSuggestion(address: 'bo@elsewhere.com', name: 'Bo Outsider'),
        ContactSuggestion(address: 'me@contoso.com', name: 'Me'),
      ].where((s) => s.name!.toLowerCase().contains(query)).toList();
}

class _Repo extends Fake implements ChatRepository {
  final reachableAsked = <String>[];

  static const _list = [
    ChatConversation(
        id: 'b', kind: ChatKind.channel, title: '#board', teamId: 't'),
    ChatConversation(id: 'x', kind: ChatKind.group, title: 'Lunch'),
  ];

  @override
  Future<List<ChatConversation>> cachedConversations(String accountId) async =>
      const [];

  @override
  Future<Either<Failure, List<ChatConversation>>> conversations(
    String accountId, {
    bool refresh = false,
  }) async =>
      const Right(_list);

  @override
  Future<Set<String>> reachable(
    String accountId,
    List<({String email, String name})> people,
  ) async {
    reachableAsked.addAll(people.map((p) => p.email));
    return {
      for (final p in people)
        if (p.email.endsWith('@contoso.com')) p.email,
    };
  }
}
