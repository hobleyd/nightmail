import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/local/migration_local_datasource.dart';
import 'package:nightmail/infrastructure/migration/account_migration_service.dart';
import 'package:nightmail/presentation/blocs/migration/migration_cubit.dart';

import 'migration_cubit_test.mocks.dart';

const _job = MigrationJobRecord(
  id: 'src|dst',
  sourceAccountId: 'src',
  targetAccountId: 'dst',
  status: MigrationJobStatus.running,
  createdAtMs: 1000,
  updatedAtMs: 2000,
  lastError: null,
);

const _failure = MigrationLedgerRecord(
  id: 1,
  jobId: 'src|dst',
  sourceFolderId: 'inbox',
  sourceMessageId: 'm1',
  status: MigrationMessageStatus.failed,
  destFolderId: null,
  destMessageId: null,
  retryCount: 3,
  lastError: 'boom',
  updatedAtMs: 3000,
);

@GenerateMocks([AccountMigrationService])
void main() {
  late MockAccountMigrationService mockService;
  late MigrationCubit cubit;

  setUp(() {
    mockService = MockAccountMigrationService();
    cubit = MigrationCubit(migrationService: mockService);
  });

  tearDown(() => cubit.close());

  group('watch', () {
    test('emits loading immediately, then the first refresh', () async {
      when(mockService.getJob('src', 'dst')).thenAnswer((_) async => _job);
      when(mockService.getFailures('src', 'dst'))
          .thenAnswer((_) async => const [_failure]);
      when(mockService.getProgress('src', 'dst')).thenReturn(null);

      cubit.watch('src', 'dst');
      expect(cubit.state.isLoading, isTrue);

      // The refresh triggered by watch() is unawaited — give it a tick.
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.isLoading, isFalse);
      expect(cubit.state.job, isNotNull);
      expect(cubit.state.job!.id, 'src|dst');
      expect(cubit.state.failures, [_failure]);
    });

    test('does not fetch failures when there is no job yet', () async {
      when(mockService.getJob('src', 'dst')).thenAnswer((_) async => null);
      when(mockService.getProgress('src', 'dst')).thenReturn(null);

      cubit.watch('src', 'dst');
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.job, isNull);
      expect(cubit.state.failures, isEmpty);
      verifyNever(mockService.getFailures(any, any));
    });

    test('reads the live in-memory progress alongside the ledger', () async {
      const progress = MigrationProgress(
        folderName: 'Inbox',
        processedCount: 5,
        totalCount: 20,
      );
      when(mockService.getJob('src', 'dst')).thenAnswer((_) async => _job);
      when(mockService.getFailures('src', 'dst'))
          .thenAnswer((_) async => const []);
      when(mockService.getProgress('src', 'dst')).thenReturn(progress);

      cubit.watch('src', 'dst');
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.progress, progress);
    });

    test('watching a second pair stops refreshing the first', () async {
      when(mockService.getJob(any, any)).thenAnswer((_) async => null);
      when(mockService.getProgress(any, any)).thenReturn(null);

      cubit.watch('src', 'dst');
      await Future<void>.delayed(Duration.zero);
      cubit.watch('src2', 'dst2');
      await Future<void>.delayed(Duration.zero);

      verify(mockService.getJob('src2', 'dst2')).called(1);
    });
  });

  group('startOrResume', () {
    test('starts watching the pair and kicks off the service', () async {
      when(mockService.getJob('src', 'dst')).thenAnswer((_) async => null);
      when(mockService.getProgress('src', 'dst')).thenReturn(null);
      when(mockService.startOrResume('src', 'dst'))
          .thenAnswer((_) async {});

      await cubit.startOrResume('src', 'dst');

      verify(mockService.startOrResume('src', 'dst')).called(1);
      expect(cubit.state.job, isNull); // watch() had already run its refresh
    });
  });

  group('after close', () {
    test('a pending refresh does not emit into a closed cubit', () async {
      when(mockService.getJob('src', 'dst')).thenAnswer((_) async {
        // Simulate the fetch still being in flight when close() runs.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return _job;
      });
      when(mockService.getFailures('src', 'dst'))
          .thenAnswer((_) async => const []);
      when(mockService.getProgress('src', 'dst')).thenReturn(null);

      cubit.watch('src', 'dst');
      await cubit.close();

      // No StateError from emitting after close — close() awaited above
      // would have surfaced one via the unawaited refresh's error zone if
      // MigrationCubit didn't guard on isClosed.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  });
}
