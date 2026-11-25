import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/presentation/widgets/chat/chat_source_picker.dart';

void main() {
  const teams =
      ChatSource(id: 'acct', kind: ChatSourceKind.teams, label: 'Teams');
  const slack = ChatSource(
      id: 'slack:T1', kind: ChatSourceKind.slack, label: 'Slack · Acme');

  Future<List<String>> pump(WidgetTester tester, List<ChatSource> sources,
      Map<String, int> unread) async {
    final chosen = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatSourcePicker(
          sources: sources,
          chosen: sources.first,
          unreadIn: (id) => unread[id] ?? 0,
          onChoose: chosen.add,
        ),
      ),
    ));
    return chosen;
  }

  testWidgets('a dropdown of the systems, each with its unread count',
      (tester) async {
    final chosen = await pump(tester, const [teams, slack], {'slack:T1': 3});
    expect(find.text('Teams'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_drop_down_rounded), findsOneWidget);

    await tester.tap(find.text('Teams'));
    await tester.pumpAndSettle();
    expect(find.text('Slack · Acme'), findsOneWidget);
    expect(find.text('3'), findsOneWidget, reason: 'Slack\'s count');
    expect(find.byIcon(Icons.check_rounded), findsOneWidget,
        reason: 'a tick on the one shown');

    await tester.tap(find.text('Slack · Acme'));
    await tester.pumpAndSettle();
    expect(chosen, ['slack:T1']);
  });

  testWidgets('one system is just its name', (tester) async {
    await pump(tester, const [slack], const {});
    expect(find.text('Slack · Acme'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_drop_down_rounded), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });
}
