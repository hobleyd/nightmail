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
import 'package:nightmail/domain/usecases/save_server_draft.dart';
import 'package:nightmail/domain/usecases/search_contacts.dart';
import 'package:nightmail/domain/usecases/send_email.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/ai/ai_compose_cubit.dart';
import 'package:nightmail/presentation/blocs/compose/compose_bloc.dart';
import 'package:nightmail/presentation/widgets/compose_dialog.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Records the draft calls the compose form makes, so the tests can assert
/// both that a draft was deleted and that nothing re-created it afterwards.
class _RecordingEmailRepository extends Fake implements EmailRepository {
  final deleted = <String>[];
  final created = <String>[];
  final updated = <String>[];
  int _nextId = 1;

  @override
  Future<Either<Failure, String>> createServerDraft({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    final id = 'draft-${_nextId++}';
    created.add(id);
    return Right(id);
  }

  @override
  Future<Either<Failure, String>> updateServerDraft({
    required String draftId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    updated.add(draftId);
    return Right(draftId);
  }

  @override
  Future<Either<Failure, Unit>> deleteServerDraft(
      {required String draftId}) async {
    deleted.add(draftId);
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

// ---------------------------------------------------------------------------

void main() {
  late _RecordingEmailRepository repository;
  late int closeCount;

  setUp(() {
    repository = _RecordingEmailRepository();
    closeCount = 0;
    sl.registerSingleton<SystemContactsRepository>(_FakeSystemContacts());
    sl.registerSingleton<SearchContacts>(SearchContacts(
      senderRepository: _FakeSenderRepository(),
      contactCacheRepository: _FakeContactCacheRepository(),
      systemContactsRepository: _FakeSystemContacts(),
      directoryContactsRepository: _FakeDirectoryContacts(),
    ));
    sl.registerSingleton<SaveServerDraft>(SaveServerDraft(repository));
    sl.registerSingleton<DeleteServerDraft>(DeleteServerDraft(repository));
    // A factory, not a singleton: the form closes the cubit it is handed when
    // it is disposed, so each pumped form needs its own.
    sl.registerFactory<AiComposeCubit>(
        () => AiComposeCubit(composeReply: _FakeComposeReply()));
  });

  tearDown(() async {
    await sl.reset();
  });

  /// Mounts a plain-text compose form (no webview) and returns its state, which
  /// is what the compose sub-window holds a [GlobalKey] to.
  Future<ComposeFormState> pumpForm(
    WidgetTester tester, {
    String? existingDraftId,
  }) async {
    final key = GlobalKey<ComposeFormState>();
    // Roughly the compose sub-window's size — the layout this path ships in.
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider(
        create: (_) => ComposeBloc(sendEmail: SendEmail(repository)),
        child: Scaffold(
          body: ComposeForm(
            key: key,
            mode: ComposeMode.newEmail,
            onClose: () => closeCount++,
            fromAddress: 'me@example.com',
            accountId: 'acct-1',
            existingDraftId: existingDraftId,
            scrollable: true,
            defaultComposeFormat: EmailBodyType.text,
          ),
        ),
      ),
    ));
    await tester.pump();
    return key.currentState!;
  }

  testWidgets(
      'the window-close path raises the same save-or-discard prompt as Cancel',
      (tester) async {
    final state = await pumpForm(tester);
    await tester.enterText(find.byType(TextField).at(2), 'Half-written');
    await tester.pump();

    state.requestClose();
    await tester.pumpAndSettle();

    expect(find.text('Save draft?'), findsOneWidget);
    expect(closeCount, 0, reason: 'the window must not close behind the prompt');

    // Let the autosave timer lapse so it doesn't fire into a torn-down tree.
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });

  testWidgets('a second close request while the prompt is up does not stack',
      (tester) async {
    final state = await pumpForm(tester);
    await tester.enterText(find.byType(TextField).at(2), 'Half-written');
    await tester.pump();

    state.requestClose();
    await tester.pumpAndSettle();
    state.requestClose();
    await tester.pumpAndSettle();

    expect(find.text('Save draft?'), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
  });

  testWidgets('discarding deletes the server draft and closes the window',
      (tester) async {
    final state = await pumpForm(tester, existingDraftId: 'draft-99');

    state.requestClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(repository.deleted, ['draft-99']);
    expect(closeCount, 1);
  });

  testWidgets('discarding cancels the pending autosave so nothing resurrects it',
      (tester) async {
    final state = await pumpForm(tester, existingDraftId: 'draft-99');
    // Typing arms the 1.5 s autosave; discarding before it fires must not
    // re-upload the draft the user just threw away.
    await tester.enterText(find.byType(TextField).at(2), 'Half-written');
    await tester.pump();

    state.requestClose();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(repository.deleted, ['draft-99']);
    expect(repository.created, isEmpty);
    expect(repository.updated, isEmpty);
  });

  testWidgets('an empty form closes without prompting', (tester) async {
    final state = await pumpForm(tester);

    state.requestClose();
    await tester.pumpAndSettle();

    expect(find.text('Save draft?'), findsNothing);
    expect(closeCount, 1);
  });
}
