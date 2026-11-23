import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/ai/ai_chunk.dart';
import 'package:nightmail/domain/entities/ai/ai_message.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_call.dart';
import 'package:nightmail/domain/entities/ai/ai_tool_result.dart';
import 'package:nightmail/domain/entities/ai/compose_draft_snapshot.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/local_attachment.dart';
import 'package:nightmail/domain/repositories/contact_cache_repository.dart';
import 'package:nightmail/domain/repositories/directory_contacts_repository.dart';
import 'package:nightmail/domain/repositories/email_repository.dart';
import 'package:nightmail/domain/repositories/sender_repository.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/domain/usecases/ai/agent/agent_loop.dart';
import 'package:nightmail/domain/usecases/ai/agent/compose_agent_tools.dart';
import 'package:nightmail/domain/usecases/ai/run_compose_assistant.dart';
import 'package:nightmail/domain/usecases/delete_server_draft.dart';
import 'package:nightmail/domain/usecases/save_server_draft.dart';
import 'package:nightmail/domain/usecases/search_contacts.dart';
import 'package:nightmail/domain/usecases/send_email.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/compose/compose_bloc.dart';
import 'package:nightmail/presentation/widgets/ai/agent_chat_panel.dart';
import 'package:nightmail/presentation/widgets/ai/draft_proposal_card.dart';
import 'package:nightmail/presentation/widgets/compose_dialog.dart';

// ---------------------------------------------------------------------------
// Fakes — the least the form needs to mount.
// ---------------------------------------------------------------------------

class _FakeEmailRepository extends Fake implements EmailRepository {
  @override
  Future<Either<Failure, String>> createServerDraft({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    List<String> bccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async =>
      const Right('draft-1');

  @override
  Future<Either<Failure, String>> updateServerDraft({
    required String draftId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    List<String> bccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async =>
      Right(draftId);

  @override
  Future<Either<Failure, Unit>> deleteServerDraft(
          {required String draftId}) async =>
      const Right(unit);
}

class _FakeSystemContacts extends Fake implements SystemContactsRepository {
  @override
  Future<void> warmUp() async {}

  @override
  Future<List<ContactSuggestion>> search(String query) async => const [];
}

class _FakeSenderRepository extends Fake implements SenderRepository {}

class _FakeContactCacheRepository extends Fake
    implements ContactCacheRepository {}

class _FakeDirectoryContacts extends Fake
    implements DirectoryContactsRepository {}

/// Answers every turn with one proposal and a sentence about it, and keeps
/// the snapshots it was handed.
class _FakeRunComposeAssistant extends Fake implements RunComposeAssistant {
  final snapshots = <ComposeDraftSnapshot>[];

  static const proposal = 'Hi Bob,\n\nFriday works for me.';

  @override
  Stream<Either<Failure, AiChunk>> call({
    required List<AiMessage> history,
    required String userInstruction,
    required ComposeDraftSnapshot snapshot,
  }) {
    snapshots.add(snapshot);
    return Stream.fromIterable(const [
      Right(AiChunk(
        delta: 'Writing a proposal…',
        finishReason: AgentLoop.toolActivityFinishReason,
        toolCalls: [
          AiToolCall(
            id: 'c1',
            name: ProposeDraftTool.toolName,
            arguments: {'text': proposal},
          ),
        ],
      )),
      Right(AiChunk(
        delta: '',
        finishReason: AgentLoop.toolResultFinishReason,
        toolResult: AiToolResult(callId: 'c1', output: '{}', isError: false),
      )),
      Right(AiChunk(delta: 'Made it friendlier.', done: true)),
    ]);
  }
}

// ---------------------------------------------------------------------------

void main() {
  const signatureHtml = '<div>Regards,</div><div>Dave</div>';
  late _FakeRunComposeAssistant assistant;

  setUp(() {
    final repository = _FakeEmailRepository();
    assistant = _FakeRunComposeAssistant();
    sl.registerSingleton<SystemContactsRepository>(_FakeSystemContacts());
    sl.registerSingleton<SearchContacts>(SearchContacts(
      senderRepository: _FakeSenderRepository(),
      contactCacheRepository: _FakeContactCacheRepository(),
      systemContactsRepository: _FakeSystemContacts(),
      directoryContactsRepository: _FakeDirectoryContacts(),
    ));
    sl.registerSingleton<SaveServerDraft>(SaveServerDraft(repository));
    sl.registerSingleton<DeleteServerDraft>(DeleteServerDraft(repository));
    sl.registerSingleton<RunComposeAssistant>(assistant);
  });

  tearDown(() async {
    await sl.reset();
  });

  /// A plain-text reply (no webview), quoting Bob, with a signature.
  Future<void> pumpReply(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider(
        create: (_) =>
            ComposeBloc(sendEmail: SendEmail(_FakeEmailRepository())),
        child: Scaffold(
          body: ComposeForm(
            mode: ComposeMode.reply,
            originalEmail: Email(
              id: 'orig',
              subject: 'Lunch',
              from: const EmailAddress(address: 'bob@example.com', name: 'Bob'),
              toRecipients: const [],
              ccRecipients: const [],
              bodyPreview: 'Lunch on Friday?',
              body: 'Lunch on Friday?',
              bodyType: EmailBodyType.text,
              isRead: true,
              receivedDateTime: DateTime.utc(2026, 11, 19, 9),
              importance: EmailImportance.normal,
            ),
            onClose: () {},
            fromAddress: 'me@example.com',
            accountId: 'acct-1',
            scrollable: true,
            defaultComposeFormat: EmailBodyType.text,
            signatureHtml: signatureHtml,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  TextField bodyField(WidgetTester tester) => tester.widget<TextField>(find
      .byWidgetPredicate((w) =>
          w is TextField &&
          w.decoration?.hintText == 'Write your message here…'));

  Future<void> sendToAssistant(WidgetTester tester, String text) async {
    final input = find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.hintText == 'Ask about this message…');
    await tester.tap(input);
    await tester.enterText(input, text);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'the AI button docks a chat beside the message; a proposal goes '
      'straight into what was written above the quote, and Undo puts it back',
      (tester) async {
    await pumpReply(tester, const Size(1200, 800));

    final controller = bodyField(tester).controller!;
    final quoteAndSignature = controller.text;
    controller.text = 'Sounds good\n$quoteAndSignature';
    final before = controller.text;

    await tester.tap(find.widgetWithText(TextButton, 'AI'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentChatPanel), findsOneWidget);
    // Docked beside the form, not over it.
    expect(tester.getRect(find.byType(AgentChatPanel)).left,
        greaterThan(tester.getRect(find.byType(TextField).first).right));

    await sendToAssistant(tester, 'Make it friendlier');

    // The model saw only the user's writing; the signature and Bob's message
    // travelled separately.
    final snapshot = assistant.snapshots.single;
    expect(snapshot.draft, 'Sounds good');
    expect(snapshot.signatureSeparated, isTrue);
    expect(snapshot.isReply, isTrue);
    expect(snapshot.originalMessage, 'Lunch on Friday?');

    // The proposal went straight into the message.
    expect(find.byType(DraftProposalCard), findsOneWidget);
    final applied = controller.text;
    expect(applied, startsWith('${_FakeRunComposeAssistant.proposal}\n\n'));
    expect(applied, contains('Regards,\nDave'));
    expect(applied, contains('Lunch on Friday?'));
    expect(applied, isNot(contains('Sounds good')));

    await tester.tap(find.widgetWithText(TextButton, 'Undo'));
    await tester.pumpAndSettle();
    expect(controller.text, before);

    await tester.tap(find.widgetWithText(TextButton, 'Apply again'));
    await tester.pumpAndSettle();
    expect(controller.text, applied);
    await tester.tap(find.widgetWithText(TextButton, 'Undo'));
    await tester.pumpAndSettle();

    // Closing the pane hands the width back; reopening keeps the chat and
    // does not put the old proposal back in.
    await tester.tap(find.widgetWithText(TextButton, 'AI'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentChatPanel), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'AI'));
    await tester.pumpAndSettle();
    expect(find.byType(DraftProposalCard), findsOneWidget);
    expect(controller.text, before);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'with the quote deleted, what is left is the message; with only its '
      'separator gone, the turn is refused on screen', (tester) async {
    await pumpReply(tester, const Size(1200, 800));
    final controller = bodyField(tester).controller!;

    await tester.tap(find.widgetWithText(TextButton, 'AI'));
    await tester.pumpAndSettle();

    // Separator line gone, Bob's text still there: not the user's to send.
    controller.text = 'Sounds good\n\nLunch on Friday?';
    await sendToAssistant(tester, 'Review it');
    expect(assistant.snapshots, isEmpty);
    expect(
        find.textContaining("Couldn't tell where your message ends",
            findRichText: true),
        findsOneWidget);

    // Quote trimmed away entirely: the whole body is the user's.
    controller.text = 'Sounds good';
    await sendToAssistant(tester, 'Review it again');
    expect(assistant.snapshots.single.draft, 'Sounds good');
    expect(controller.text, _FakeRunComposeAssistant.proposal);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      "the compose title bar and footer line up with the AI pane's header "
      'and input box', (tester) async {
    await pumpReply(tester, const Size(1200, 800));
    await tester.tap(find.widgetWithText(TextButton, 'AI'));
    await tester.pumpAndSettle();

    final pane = tester.getRect(find.byType(AgentChatPanel));
    final dividers = [
      for (final e in find.byType(Divider).evaluate())
        tester.getRect(find.byWidget(e.widget)),
    ];
    final paneDividers = dividers.where((r) => r.left >= pane.left);
    final formDividers = dividers.where((r) => r.right <= pane.left);

    // Header: the two dividers under the titles share a line.
    final paneHeader = paneDividers.map((r) => r.top).reduce(math.min);
    expect(formDividers.map((r) => r.top), contains(paneHeader));

    // Footer: the divider above it meets the top of the chat input box.
    final input = find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.hintText == 'Ask about this message…');
    final box = tester.getRect(find
        .ancestor(
            of: input,
            matching: find.byWidgetPredicate((w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).border != null))
        .first);
    final footerDivider = formDividers.map((r) => r.top).reduce(math.max);
    expect(footerDivider, box.top);

    // And the footer got smaller: under 45px from its divider to the bottom.
    expect(800 - footerDivider, lessThan(45));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'the input box grows with the text up to a fifth of the pane, then '
      'scrolls', (tester) async {
    await pumpReply(tester, const Size(1200, 800));
    await tester.tap(find.widgetWithText(TextButton, 'AI'));
    await tester.pumpAndSettle();

    final input = find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.hintText == 'Ask about this message…');
    Rect box() => tester.getRect(find
        .ancestor(
            of: input,
            matching: find.byWidgetPredicate((w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).border != null))
        .first);
    ScrollPosition scroll() => tester
        .state<ScrollableState>(find.descendant(
            of: input, matching: find.byType(Scrollable)))
        .position;
    // The field's height less its text's: the padding the text sits in.
    double fieldSlack() =>
        tester.getSize(input).height -
        tester
            .getSize(find.descendant(
                of: input, matching: find.byType(EditableText)))
            .height;

    // At rest, and with a short line: one line.
    expect(box().height, 32);
    await tester.enterText(input, 'Short');
    await tester.pump();
    expect(box().height, 32);
    final oneLineSlack = fieldSlack();

    // Three typed lines: taller, every line showing.
    await tester.enterText(input, 'One\nTwo\nThree');
    await tester.pump();
    final threeLines = box().height;
    expect(threeLines, greaterThan(32));
    expect(scroll().maxScrollExtent, 0);

    // A long paragraph wraps: taller again, still nothing hidden.
    await tester.enterText(input, List.filled(30, 'word').join(' '));
    await tester.pump();
    expect(box().height, greaterThan(threeLines));
    expect(scroll().maxScrollExtent, 0);
    // ...and no spare blank line: the padding around the text is what the
    // one-line box has.
    expect(fieldSlack(), oneLineSlack);

    // Far more than fits: capped at a fifth of the pane, and scrollable.
    final pane = tester.getRect(find.byType(AgentChatPanel));
    await tester.enterText(input, List.filled(40, 'line').join('\n'));
    await tester.pump();
    expect(box().height, lessThanOrEqualTo(pane.height * 0.2 + 2));
    expect(box().height, greaterThan(pane.height * 0.2 - 48));
    expect(scroll().maxScrollExtent, greaterThan(0));

    // Clearing it (as a send does) drops back to one line.
    await tester.enterText(input, '');
    await tester.pump();
    expect(box().height, 32);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the pane fits the default 640px compose window',
      (tester) async {
    await pumpReply(tester, const Size(640, 520));

    await tester.tap(find.widgetWithText(TextButton, 'AI'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentChatPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.widgetWithText(FilledButton, 'Send')).right,
        lessThanOrEqualTo(tester.getRect(find.byType(AgentChatPanel)).left));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'a phone puts the message in the top half and the chat below it; Back '
      'returns to the ordinary compose screen', (tester) async {
    await pumpReply(tester, const Size(390, 800));
    final body = find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.hintText == 'Write your message here…');
    final bodyState = tester.state(body);

    await tester.tap(find.widgetWithText(TextButton, 'AI'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final pane = tester.getRect(find.byType(AgentChatPanel));
    final message = tester.getRect(body);
    expect(message.bottom, lessThanOrEqualTo(pane.top));
    expect(pane.top, closeTo(400, 80), reason: 'about half way down');
    expect(pane.bottom, closeTo(800, 1));
    expect(find.widgetWithText(FilledButton, 'Send'), findsNothing);

    // The system back gesture closes the pane, not the message.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AgentChatPanel), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Send'), findsOneWidget);
    // The same editor all along — never remounted.
    expect(tester.state(body), same(bodyState));

    // And the pane's own back arrow does the same.
    await tester.tap(find.widgetWithText(TextButton, 'AI'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentChatPanel), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Send'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
