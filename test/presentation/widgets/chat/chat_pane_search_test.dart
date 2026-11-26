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
    expect(find.text('Bob Brown'), findsOneWidget);
    // Not reachable: an outsider with no chat.
    expect(find.text('Bo Outsider'), findsNothing);
    expect(find.text('#board'), findsOneWidget);
    // A one-on-one with someone offered as a person is not listed twice.
    expect(find.text('Bob (1:1)'), findsNothing);
    expect(repo.reachableAsked, ['bob@contoso.com', 'bo@elsewhere.com']);

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

  testWidgets('Enter picks the first match, a person before a chat',
      (tester) async {
    final picked = await show(tester);
    await type(tester, 'bob');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(picked.people.single.email, 'bob@contoso.com');
    expect(picked.chats, isEmpty);
  });

  testWidgets('Enter opens a chat when no one matches', (tester) async {
    final picked = await show(tester);
    await type(tester, 'lunch');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(picked.chats.single.title, 'Lunch');
  });

  testWidgets('a name is asked about once, not per keystroke',
      (tester) async {
    await show(tester);
    await type(tester, 'bo');
    await type(tester, 'bob');
    await type(tester, 'bo');
    expect(repo.reachableAsked, ['bob@contoso.com', 'bo@elsewhere.com']);
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
      title: 'Bob (1:1)',
      members: [ChatMember(displayName: 'Bob Brown', email: 'bob@contoso.com')],
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
