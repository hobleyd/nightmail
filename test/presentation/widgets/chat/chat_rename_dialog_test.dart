import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/presentation/widgets/chat/chat_rename_dialog.dart';

/// The rename dialog: a Slack channel's `#` is not part of its name, and a
/// refusal stays on screen with the dialog open to try again.
void main() {
  Future<Future<bool>> open(WidgetTester tester, ChatConversation c,
      Future<String?> Function(String) rename) async {
    late Future<bool> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => result = showChatRenameDialog(context,
              conversation: c, rename: rename),
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('a Slack channel is named without its #', (tester) async {
    final sent = <String>[];
    final result = await open(
        tester,
        const ChatConversation(id: 'C1', kind: ChatKind.space, title: '#general'),
        (t) async {
      sent.add(t);
      return null;
    });
    expect(find.text('Rename channel'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'general');
    await tester.enterText(find.byType(TextField), 'releases');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(sent, ['releases']);
    expect(await result, isTrue);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the name it already has is not sent', (tester) async {
    final sent = <String>[];
    Future<String?> rename(String t) async {
      sent.add(t);
      return null;
    }

    var result = await open(
        tester,
        const ChatConversation(id: 'g', kind: ChatKind.group, title: 'Ann, Bob'),
        rename);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);

    result = await open(
        tester,
        const ChatConversation(id: 'C1', kind: ChatKind.space, title: '#general'),
        rename);
    await tester.enterText(find.byType(TextField), 'General ');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
    expect(sent, isEmpty);
  });

  testWidgets('a refusal is shown and the dialog stays open', (tester) async {
    final result = await open(
        tester,
        const ChatConversation(id: 'g', kind: ChatKind.group, title: 'Ann, Bob'),
        (_) async => 'Only owners can rename it');
    expect(find.text('Rename chat'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Launch');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Only owners can rename it'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });
}
