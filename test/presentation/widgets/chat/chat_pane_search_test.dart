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
import 'package:nightmail/presentation/widgets/chat/chat_pane_search.dart';

/// The pane's search finds anyone or any chat by name: the email's people,
/// address-book people only when a chat with them can exist, chats and
/// channels from the listing.
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

  Future<({List<ChatPerson> people, List<ChatConversation> chats})> show(
      WidgetTester tester) async {
    final people = <ChatPerson>[];
    final chats = <ChatConversation>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          child: ChatPaneList(
            chatId: 'acct',
            account: account,
            people: const [
              ChatPerson(email: 'ann@contoso.com', name: 'Ann Lee'),
              ChatPerson(email: 'bea@contoso.com', name: 'Bea Bolt'),
            ],
            chats: const [],
            selected: null,
            onPerson: people.add,
            onChat: chats.add,
          ),
        ),
      ),
    ));
    return (people: people, chats: chats);
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
  }

  testWidgets('lists nothing until something is typed', (tester) async {
    await show(tester);
    expect(find.text('No unread chats'), findsOneWidget);
    expect(find.text('Ann Lee'), findsNothing);
    expect(repo.listed, 0);
  });

  testWidgets('finds the email\'s people, reachable contacts and channels',
      (tester) async {
    final picked = await show(tester);
    await type(tester, 'bo');

    expect(find.text('Bea Bolt'), findsOneWidget); // on the email
    expect(find.text('Bob Brown'), findsOneWidget); // reachable, no chat
    // Not reachable: an outsider with no chat.
    expect(find.text('Bo Outsider'), findsNothing);
    expect(find.text('#board'), findsOneWidget);
    // Cid has a one-on-one: offered as that chat, not again as a person.
    expect(find.text('Cid (1:1)'), findsOneWidget);
    expect(find.text('Cid Bond'), findsNothing);
    expect(repo.reachableAsked,
        ['bob@contoso.com', 'bo@elsewhere.com', 'cid@contoso.com']);

    // The email's people, then chats, then the address book: rows found
    // late go last, under the ones already shown.
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('Bea Bolt'), lessThan(y('#board')));
    expect(y('#board'), lessThan(y('Bob Brown')));

    await tester.tap(find.text('#board'));
    await tester.pumpAndSettle();
    expect(picked.chats.single.title, '#board');
    // The pick clears the field and the list goes back to unread.
    expect(find.text('No unread chats'), findsOneWidget);
  });

  testWidgets('tapping a person picks them', (tester) async {
    final picked = await show(tester);
    await type(tester, 'ann');
    await tester.tap(find.text('Ann Lee'));
    await tester.pumpAndSettle();
    expect(picked.people.single.email, 'ann@contoso.com');
  });

  Future<void> enter(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('Enter picks the first row: someone on the email',
      (tester) async {
    final picked = await show(tester);
    await type(tester, 'bea');
    await enter(tester);
    expect(picked.people.single.email, 'bea@contoso.com');
  });

  testWidgets('Enter picks a chat before an address-book person',
      (tester) async {
    final picked = await show(tester);
    await type(tester, 'b');
    await enter(tester);
    expect(picked.people.single.email, 'bea@contoso.com');

    await type(tester, 'lunch');
    await enter(tester);
    expect(picked.chats.single.title, 'Lunch');
  });

  testWidgets('Enter picks an address-book person when nothing else matches',
      (tester) async {
    final picked = await show(tester);
    await type(tester, 'bob');
    await enter(tester);
    expect(picked.people.single.email, 'bob@contoso.com');
    expect(picked.chats, isEmpty);
  });

  testWidgets('a person with a one-on-one opens the chat', (tester) async {
    final picked = await show(tester);
    await type(tester, 'cid');
    await enter(tester);
    expect(picked.chats.single.title, 'Cid (1:1)');
    expect(picked.people, isEmpty);
  });

  testWidgets('a name is asked about once, not per keystroke',
      (tester) async {
    await show(tester);
    await type(tester, 'bo');
    await type(tester, 'bob');
    await type(tester, 'bo');
    expect(repo.reachableAsked,
        ['bob@contoso.com', 'bo@elsewhere.com', 'cid@contoso.com']);
    expect(repo.listed, 1);
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
        ContactSuggestion(address: 'cid@contoso.com', name: 'Cid Bond'),
        ContactSuggestion(address: 'me@contoso.com', name: 'Me'),
      ].where((s) => s.name!.toLowerCase().contains(query)).toList();
}

class _Repo extends Fake implements ChatRepository {
  final reachableAsked = <String>[];
  int listed = 0;

  static const _list = [
    ChatConversation(
        id: 'b', kind: ChatKind.channel, title: '#board', teamId: 't'),
    ChatConversation(id: 'x', kind: ChatKind.group, title: 'Lunch'),
    ChatConversation(
      id: 'o',
      kind: ChatKind.oneOnOne,
      title: 'Cid (1:1)',
      members: [ChatMember(displayName: 'Cid Bond', email: 'cid@contoso.com')],
    ),
  ];

  @override
  Future<List<ChatConversation>> cachedConversations(String accountId) async =>
      const [];

  @override
  Future<Either<Failure, List<ChatConversation>>> conversations(
    String accountId, {
    bool refresh = false,
  }) async {
    listed++;
    return const Right(_list);
  }

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
