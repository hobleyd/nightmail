import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/local_attachment.dart';
import 'package:nightmail/domain/repositories/contact_cache_repository.dart';
import 'package:nightmail/domain/repositories/directory_contacts_repository.dart';
import 'package:nightmail/domain/repositories/email_repository.dart';
import 'package:nightmail/domain/repositories/sender_repository.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/domain/usecases/ai/compose_reply.dart';
import 'package:nightmail/domain/usecases/delete_server_draft.dart';
import 'package:nightmail/domain/usecases/get_raw_email_bytes.dart';
import 'package:nightmail/domain/usecases/save_server_draft.dart';
import 'package:nightmail/domain/usecases/search_contacts.dart';
import 'package:nightmail/domain/usecases/send_email.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/ai/ai_compose_cubit.dart';
import 'package:nightmail/presentation/blocs/compose/compose_bloc.dart';
import 'package:nightmail/presentation/widgets/compose_dialog.dart';
import 'package:nightmail/presentation/widgets/forward_as_attachment.dart';

// ---------------------------------------------------------------------------
// ComposeForm seeded by a list selection's Forward: the subject it is handed
// and the .eml of each forwarded message, which must be on screen and go out
// with the send exactly as given.
// ---------------------------------------------------------------------------

/// Records what each send carried; drafts are accepted and forgotten.
class _RecordingEmailRepository extends Fake implements EmailRepository {
  final sends = <({String subject, List<LocalAttachment> attachments})>[];

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

  @override
  Future<Either<Failure, Unit>> sendEmail({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    List<String> bccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
    String? accountId,
  }) async {
    sends.add((subject: subject, attachments: newAttachments));
    return const Right(unit);
  }
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

class _FakeComposeReply extends Fake implements ComposeReply {}

/// Answers every fetch from [answer] — by default with the id as the source.
class _FakeGetRawEmailBytes extends Fake implements GetRawEmailBytes {
  Future<Either<Failure, Uint8List>> Function(String id) answer =
      (id) async => Right(Uint8List.fromList(utf8.encode('source of $id')));
  final asked = <String>[];

  @override
  Future<Either<Failure, Uint8List>> call(String emailId) {
    asked.add(emailId);
    return answer(emailId);
  }
}

LocalAttachment _eml(String name, String source) => LocalAttachment(
      name: name,
      mimeType: 'message/rfc822',
      bytes: Uint8List.fromList(utf8.encode(source)),
    );

void main() {
  late _RecordingEmailRepository repository;
  late _FakeGetRawEmailBytes getRaw;

  setUp(() {
    repository = _RecordingEmailRepository();
    sl.registerSingleton<SystemContactsRepository>(_FakeSystemContacts());
    sl.registerSingleton<SearchContacts>(SearchContacts(
      senderRepository: _FakeSenderRepository(),
      contactCacheRepository: _FakeContactCacheRepository(),
      systemContactsRepository: _FakeSystemContacts(),
      directoryContactsRepository: _FakeDirectoryContacts(),
    ));
    sl.registerSingleton<SaveServerDraft>(SaveServerDraft(repository));
    sl.registerSingleton<DeleteServerDraft>(DeleteServerDraft(repository));
    sl.registerFactory<AiComposeCubit>(
        () => AiComposeCubit(composeReply: _FakeComposeReply()));
    getRaw = _FakeGetRawEmailBytes();
    sl.registerSingleton<GetRawEmailBytes>(getRaw);
  });

  tearDown(() async => sl.reset());

  /// A plain-text form (no webview) seeded as the list's Forward seeds it.
  Future<void> pumpForm(
    WidgetTester tester, {
    String? initialSubject,
    List<LocalAttachment> initialAttachments = const [],
    List<ForwardedMessage> forwardAsAttachments = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider(
        create: (_) => ComposeBloc(sendEmail: SendEmail(repository)),
        child: Scaffold(
          body: ComposeForm(
            mode: ComposeMode.newEmail,
            onClose: () {},
            fromAddress: 'me@example.com',
            accountId: 'acct-1',
            scrollable: true,
            defaultComposeFormat: EmailBodyType.text,
            initialSubject: initialSubject,
            initialAttachments: initialAttachments,
            forwardAsAttachments: forwardAsAttachments,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  // To, Cc, then Subject — see compose_close_test.dart.
  final toField = find.byType(TextField).at(0);
  final subjectField = find.byType(TextField).at(2);

  String subjectText(WidgetTester tester) =>
      tester.widget<TextField>(subjectField).controller!.text;

  /// Avoids `pumpAndSettle` once Send is pressed: the "Sending…" shimmer
  /// repeats forever.
  Future<void> send(WidgetTester tester) async {
    await tester.enterText(toField, 'you@example.com');
    await tester.pump();
    await tester.tap(find.text('Send'));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  testWidgets('starts with the subject it was handed', (tester) async {
    await pumpForm(tester, initialSubject: 'Fwd: Quarterly numbers');

    expect(subjectText(tester), 'Fwd: Quarterly numbers');
  });

  testWidgets('starts with no subject when handed none', (tester) async {
    await pumpForm(tester, initialAttachments: [_eml('A.eml', 'a')]);

    expect(subjectText(tester), '');
  });

  testWidgets('shows each forwarded message as an attachment',
      (tester) async {
    await pumpForm(tester, initialAttachments: [
      _eml('Quarterly numbers.eml', 'one'),
      _eml('Re_ Meeting.eml', 'two'),
    ]);

    expect(find.text('Quarterly numbers.eml'), findsOneWidget);
    expect(find.text('Re_ Meeting.eml'), findsOneWidget);
  });

  testWidgets('sends the attachments as they were handed over',
      (tester) async {
    await pumpForm(
      tester,
      initialSubject: 'Fwd: Quarterly numbers',
      initialAttachments: [
        _eml('Quarterly numbers.eml', 'one'),
        _eml('Re_ Meeting.eml', 'two'),
      ],
    );

    await send(tester);

    final sent = repository.sends.single;
    expect(sent.subject, 'Fwd: Quarterly numbers');
    expect(
      sent.attachments.map((a) => (a.name, a.mimeType, utf8.decode(a.bytes))),
      [
        ('Quarterly numbers.eml', 'message/rfc822', 'one'),
        ('Re_ Meeting.eml', 'message/rfc822', 'two'),
      ],
    );
  });

  // The desktop compose window is handed ids, not bytes, and fetches the
  // .eml files itself once it is open.
  group('forwarded messages fetched by the form', () {
    const two = [
      (id: 'm1', subject: 'Quarterly numbers'),
      (id: 't2', subject: 'Re: Offsite plans'),
    ];

    testWidgets('are fetched and attached, in order, once the form opens',
        (tester) async {
      await pumpForm(tester, forwardAsAttachments: two);
      await tester.pump();

      expect(getRaw.asked, ['m1', 't2']);
      expect(find.text('Quarterly numbers.eml'), findsOneWidget);
      expect(find.text('Re_ Offsite plans.eml'), findsOneWidget);
    });

    testWidgets('show one pending chip until they arrive', (tester) async {
      final gate = Completer<Either<Failure, Uint8List>>();
      getRaw.answer = (_) => gate.future;
      await pumpForm(tester, forwardAsAttachments: two);

      expect(find.text('Attaching 2 messages…'), findsOneWidget);

      gate.complete(Right(Uint8List.fromList([1])));
      await tester.pump();
      await tester.pump();
      expect(find.text('Attaching 2 messages…'), findsNothing);
      expect(find.text('Quarterly numbers.eml'), findsOneWidget);
    });

    testWidgets('a failure attaches none and says why', (tester) async {
      getRaw.answer = (id) async => id == 't2'
          ? const Left(NetworkFailure(message: 'No connection'))
          : Right(Uint8List.fromList([1]));
      await pumpForm(tester, forwardAsAttachments: two);
      await tester.pump();

      expect(
          find.text("Couldn't attach the forwarded messages: No connection"),
          findsOneWidget);
      expect(find.text('Quarterly numbers.eml'), findsNothing);
      expect(find.textContaining('Attaching'), findsNothing);
    });

    testWidgets('Send pressed mid-fetch waits, then sends them',
        (tester) async {
      final gate = Completer<Either<Failure, Uint8List>>();
      getRaw.answer = (id) => gate.future;
      await pumpForm(tester,
          initialSubject: 'Fwd: Quarterly numbers',
          forwardAsAttachments: [two.first]);

      await send(tester);
      expect(repository.sends, isEmpty,
          reason: 'it must not go before its attachments');

      gate.complete(Right(Uint8List.fromList(utf8.encode('one'))));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      final sent = repository.sends.single;
      expect(sent.attachments.map((a) => (a.name, a.mimeType)),
          [('Quarterly numbers.eml', 'message/rfc822')]);
    });

    testWidgets(
        'a fetch that fails while Send waits holds the send, '
        'and a second Send goes without', (tester) async {
      final gate = Completer<Either<Failure, Uint8List>>();
      getRaw.answer = (id) => gate.future;
      await pumpForm(tester, forwardAsAttachments: [two.first]);

      await send(tester);
      gate.complete(const Left(NetworkFailure(message: 'No connection')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }

      expect(repository.sends, isEmpty,
          reason: 'the user has not yet seen why the attachment is missing');
      expect(find.text("Couldn't attach the forwarded message: No connection"),
          findsOneWidget);

      await tester.tap(find.text('Send'));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(repository.sends.single.attachments, isEmpty);
    });
  });
}
