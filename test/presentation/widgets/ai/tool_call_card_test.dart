import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/blocs/ai/ai_folder_chat_state.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_event.dart';
import 'package:nightmail/presentation/widgets/ai/tool_call_card.dart';

Widget _wrap(
  AiToolItem item, {
  ValueChanged<EmailListResultSet>? onShowInList,
}) {
  return MaterialApp(
    home: Scaffold(
      // Width-bounded so the collapsed one-liner can lay out its Flexible
      // preview without unbounded-width errors.
      body: SizedBox(
        width: 360,
        child: ToolCallCard(item: item, onShowInList: onShowInList),
      ),
    ),
  );
}

const _twoHits = '{"count": 2, "emails": [{"id": "a"}, {"id": "b"}]}';

AiToolItem _item(
  String name,
  Map<String, dynamic> args, {
  String? output = _twoHits,
  AiToolStatus status = AiToolStatus.complete,
}) =>
    AiToolItem(
      id: 'item',
      callId: 'call',
      name: name,
      args: args,
      output: output,
      status: status,
      turnFolderId: 'inbox',
      turnAccountId: 'account-1',
    );

void main() {
  group('ToolCallCard', () {
    testWidgets(
      'complete item renders collapsed, then expands to reveal input/output JSON',
      (tester) async {
        const item = AiToolItem(
          id: 'item-1',
          callId: 'call-1',
          name: 'search_emails',
          args: {'query': 'invoices'},
          output: '{"count": 3}',
          status: AiToolStatus.complete,
        );

        await tester.pumpWidget(_wrap(item));

        // Collapsed one-liner: humanized name, arg preview, done glyph.
        expect(find.text('Searched emails'), findsOneWidget);
        expect(find.text('invoices'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);

        // Body is hidden while collapsed.
        expect(find.text('INPUT'), findsNothing);
        expect(find.text('OUTPUT'), findsNothing);
        expect(find.textContaining('"count"'), findsNothing);

        // Tap the header to expand.
        await tester.tap(find.byType(InkWell));
        await tester.pump();

        // Body now reveals the input args and output JSON.
        expect(find.text('INPUT'), findsOneWidget);
        expect(find.text('OUTPUT'), findsOneWidget);
        expect(find.textContaining('"query"'), findsOneWidget);
        expect(find.textContaining('"count"'), findsOneWidget);
      },
    );

    testWidgets(
      'error item renders auto-expanded showing the error text',
      (tester) async {
        const item = AiToolItem(
          id: 'item-2',
          callId: 'call-2',
          name: 'get_email',
          args: {'id': 'msg-99'},
          output: '{"error": "mailbox unavailable"}',
          status: AiToolStatus.error,
        );

        await tester.pumpWidget(_wrap(item));

        // Forced open: no tap required to see the body and the error glyph.
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
        expect(find.text('INPUT'), findsOneWidget);
        expect(find.text('OUTPUT'), findsOneWidget);
        expect(find.textContaining('mailbox unavailable'), findsOneWidget);

        // Tapping an error card must not collapse it.
        await tester.tap(find.byType(InkWell));
        await tester.pump();
        expect(find.text('OUTPUT'), findsOneWidget);
        expect(find.textContaining('mailbox unavailable'), findsOneWidget);
      },
    );

    testWidgets(
      'pretty-print falls back to the raw string for non-JSON output',
      (tester) async {
        const item = AiToolItem(
          id: 'item-3',
          callId: 'call-3',
          name: 'list_folders',
          args: {},
          output: 'not valid json <<<',
          status: AiToolStatus.complete,
        );

        await tester.pumpWidget(_wrap(item));

        // Expand to render the output section.
        await tester.tap(find.byType(InkWell));
        await tester.pump();

        // Raw string rendered verbatim, no exception thrown.
        expect(find.textContaining('not valid json <<<'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('agentEmailResults', () {
    test('a search replays its query in the turn\'s folder and account', () {
      expect(
        agentEmailResults(_item('search_emails', {'query': 'invoice'})),
        const EmailListResultSet(
          title: 'invoice',
          accountId: 'account-1',
          query: 'invoice',
          folderId: 'inbox',
          top: 50,
        ),
      );
    });

    test('a folder and limit the model named win over the defaults', () {
      final r = agentEmailResults(_item(
          'search_emails', {'query': 'x', 'folder_id': 'archive', 'limit': '7'}));
      expect(r?.folderId, 'archive');
      expect(r?.top, 7);
    });

    test('an unread listing is a listing, not a search', () {
      final r = agentEmailResults(
          _item('list_emails', {'unread_only': true, 'limit': 500}));
      expect(r?.query, isNull);
      expect(r?.unreadOnly, isTrue);
      expect(r?.title, 'Unread emails');
      expect(r?.top, 100, reason: 'clamped like the tool clamps it');
    });

    test('nothing to show for other tools, no hits, or a call not done', () {
      expect(agentEmailResults(_item('get_email', {'id': 'a'})), isNull);
      expect(
          agentEmailResults(_item('search_emails', {'query': 'x'},
              output: '{"count": 0, "emails": []}')),
          isNull);
      expect(
          agentEmailResults(_item('search_emails', {'query': 'x'},
              output: null, status: AiToolStatus.running)),
          isNull);
      expect(
          agentEmailResults(_item('search_emails', {'query': 'x'},
              status: AiToolStatus.error)),
          isNull);
    });
  });

  group('ToolCallCard show in list', () {
    testWidgets('offers the hits and hands over the result set',
        (tester) async {
      EmailListResultSet? shown;
      await tester.pumpWidget(_wrap(
        _item('search_emails', {'query': 'invoice'}),
        onShowInList: (r) => shown = r,
      ));

      await tester.tap(find.text('Show 2 emails in list'));
      expect(shown?.query, 'invoice');
    });

    testWidgets('a host with no email list gets no action', (tester) async {
      await tester.pumpWidget(_wrap(_item('search_emails', {'query': 'x'})));
      expect(find.textContaining('in list'), findsNothing);
    });
  });
}
