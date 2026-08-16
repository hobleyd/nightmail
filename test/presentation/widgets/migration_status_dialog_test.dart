import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/local/migration_local_datasource.dart';
import 'package:nightmail/infrastructure/migration/account_migration_service.dart';
import 'package:nightmail/presentation/blocs/migration/migration_cubit.dart';
import 'package:nightmail/presentation/blocs/migration/migration_state.dart';
import 'package:nightmail/presentation/widgets/migration_status_dialog.dart';

import 'migration_status_dialog_test.mocks.dart';

MigrationJobRecord _job(MigrationJobStatus status, {String? lastError}) =>
    MigrationJobRecord(
      id: 'src|tgt',
      sourceAccountId: 'src',
      targetAccountId: 'tgt',
      status: status,
      createdAtMs: 0,
      updatedAtMs: 0,
      lastError: lastError,
    );

MigrationLedgerRecord _failure() => MigrationLedgerRecord(
      id: 1,
      jobId: 'src|tgt',
      sourceFolderId: 'INBOX',
      sourceMessageId: 'msg-1',
      status: MigrationMessageStatus.failed,
      destFolderId: null,
      destMessageId: null,
      retryCount: 3,
      lastError: 'boom',
      updatedAtMs: 0,
    );

@GenerateMocks([MigrationCubit])
void main() {
  late MockMigrationCubit mockCubit;

  setUp(() {
    mockCubit = MockMigrationCubit();
    when(mockCubit.stream).thenAnswer((_) => const Stream.empty());
  });

  Widget wrap() => MaterialApp(
        home: BlocProvider<MigrationCubit>.value(
          value: mockCubit,
          child: const MigrationStatusDialog(
            sourceAccountLabel: 'Woodgate Beach',
            targetAccountLabel: 'O365',
          ),
        ),
      );

  testWidgets('a clean completion shows the plain success headline',
      (tester) async {
    when(mockCubit.state).thenReturn(
        MigrationState(job: _job(MigrationJobStatus.completed)));

    await tester.pumpWidget(wrap());

    expect(find.text('Migration complete'), findsOneWidget);
  });

  // The requirement was "if they fail again, reported on" — a plain green
  // check on a job that permanently dropped messages would misreport that,
  // even though the failure list is drawn underneath either way.
  testWidgets(
      'a completion with permanent failures says so in the headline, not '
      'just the list below', (tester) async {
    when(mockCubit.state).thenReturn(MigrationState(
      job: _job(MigrationJobStatus.completed),
      failures: [_failure()],
    ));

    await tester.pumpWidget(wrap());

    expect(find.text('Migration complete'), findsNothing);
    expect(
        find.text('Finished — some messages could not be copied'),
        findsOneWidget);
    expect(find.text('1 message(s) could not be copied after retrying:'),
        findsOneWidget);
  });

  testWidgets(
      'a running job shows the current folder and processed/total count '
      'under the spinner', (tester) async {
    when(mockCubit.state).thenReturn(MigrationState(
      job: _job(MigrationJobStatus.running),
      progress: const MigrationProgress(
        folderName: 'Inbox',
        processedCount: 12,
        totalCount: 340,
      ),
    ));

    await tester.pumpWidget(wrap());

    expect(find.text('Migrating…'), findsOneWidget);
    expect(find.text('Inbox — 12 of 340'), findsOneWidget);
  });

  testWidgets('omits the total when the provider reported none for the folder',
      (tester) async {
    when(mockCubit.state).thenReturn(MigrationState(
      job: _job(MigrationJobStatus.running),
      progress: const MigrationProgress(
        folderName: 'Projects/Q1',
        processedCount: 4,
        totalCount: null,
      ),
    ));

    await tester.pumpWidget(wrap());

    expect(find.text('Projects/Q1 — 4 processed'), findsOneWidget);
  });

  testWidgets('a non-running job shows no progress line even if one is held',
      (tester) async {
    when(mockCubit.state).thenReturn(MigrationState(
      job: _job(MigrationJobStatus.completed),
      progress: const MigrationProgress(
        folderName: 'Inbox',
        processedCount: 340,
        totalCount: 340,
      ),
    ));

    await tester.pumpWidget(wrap());

    expect(find.textContaining('Inbox —'), findsNothing);
  });

  group('paused for re-authentication', () {
    testWidgets(
        'states plainly that the migration is stalled on sign-in, not just '
        'the terse headline', (tester) async {
      when(mockCubit.state).thenReturn(MigrationState(
        job: _job(MigrationJobStatus.paused, lastError: 'token expired'),
      ));

      await tester.pumpWidget(wrap());

      expect(find.text('Paused — needs re-authentication'), findsOneWidget);
      expect(
          find.textContaining(
              'needs to be signed in again before it can continue'),
          findsOneWidget);
      // The raw exception text is still shown, just secondary to the plain
      // explanation above it.
      expect(find.text('token expired'), findsOneWidget);
    });

    testWidgets('the explanation appears even without a stored error message',
        (tester) async {
      when(mockCubit.state).thenReturn(
          MigrationState(job: _job(MigrationJobStatus.paused)));

      await tester.pumpWidget(wrap());

      expect(
          find.textContaining(
              'needs to be signed in again before it can continue'),
          findsOneWidget);
    });

    testWidgets(
        'a non-paused job with an error shows the raw message alone, no '
        'sign-in explanation', (tester) async {
      when(mockCubit.state).thenReturn(MigrationState(
        job: _job(MigrationJobStatus.failed, lastError: 'disk full'),
      ));

      await tester.pumpWidget(wrap());

      expect(find.text('disk full'), findsOneWidget);
      expect(
          find.textContaining('needs to be signed in again'), findsNothing);
    });
  });

  group('safe-to-close note', () {
    testWidgets('is shown while a job is running', (tester) async {
      when(mockCubit.state).thenReturn(
          MigrationState(job: _job(MigrationJobStatus.running)));

      await tester.pumpWidget(wrap());

      expect(
          find.textContaining('safe to close'),
          findsOneWidget);
    });

    testWidgets('is shown even before the job has loaded', (tester) async {
      when(mockCubit.state).thenReturn(const MigrationState());

      await tester.pumpWidget(wrap());

      expect(
          find.textContaining('safe to close'),
          findsOneWidget);
    });

    testWidgets('is shown after the job has completed', (tester) async {
      when(mockCubit.state).thenReturn(
          MigrationState(job: _job(MigrationJobStatus.completed)));

      await tester.pumpWidget(wrap());

      expect(
          find.textContaining('safe to close'),
          findsOneWidget);
    });
  });
}
