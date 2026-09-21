import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/out_of_office_settings.dart';
import 'package:nightmail/domain/usecases/get_out_of_office.dart';
import 'package:nightmail/domain/usecases/set_out_of_office.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/presentation/blocs/out_of_office/out_of_office_cubit.dart';
import 'package:nightmail/presentation/blocs/out_of_office/out_of_office_state.dart';

import 'out_of_office_cubit_test.mocks.dart';

const _account = GmailAccount(
  id: 'acct-1',
  displayName: 'Test',
  emailAddress: 'me@example.com',
);

const _emptySettings = OutOfOfficeSettings(enabled: false);

@GenerateMocks([GetOutOfOffice, SetOutOfOffice, AccountManager])
void main() {
  late MockGetOutOfOffice mockGet;
  late MockSetOutOfOffice mockSet;
  late MockAccountManager mockAccountManager;
  late OutOfOfficeCubit cubit;

  setUp(() {
    // Mockito cannot auto-generate dummy values for sealed/abstract types
    // like Either, so we register one explicitly.
    provideDummy<Either<Failure, OutOfOfficeSettings>>(
        const Right(_emptySettings));
    provideDummy<Either<Failure, Unit>>(const Right(unit));

    mockGet = MockGetOutOfOffice();
    mockSet = MockSetOutOfOffice();
    mockAccountManager = MockAccountManager();
    cubit = OutOfOfficeCubit(
      getOutOfOffice: mockGet,
      setOutOfOffice: mockSet,
      accountManager: mockAccountManager,
    );

    when(mockAccountManager.activeAccount).thenReturn(_account);
    when(mockAccountManager.hasOutOfOfficeWriteAccess(any))
        .thenAnswer((_) async => true);
  });

  tearDown(() => cubit.close());

  group('load', () {
    test('reports an error when no account is signed in and none is given',
        () async {
      when(mockAccountManager.activeAccount).thenReturn(null);

      await cubit.load();

      expect(cubit.state.status, OutOfOfficeStatus.error);
      expect(cubit.state.errorMessage, 'No account is signed in yet.');
    });

    test('loads settings for the active account when none is given',
        () async {
      when(mockGet('acct-1')).thenAnswer((_) async => const Right(_emptySettings));

      await cubit.load();

      expect(cubit.state.accountId, 'acct-1');
      expect(cubit.state.status, OutOfOfficeStatus.ready);
      verify(mockGet('acct-1')).called(1);
    });

    test('loads settings for an explicitly given account, not the active one',
        () async {
      when(mockGet('acct-2')).thenAnswer((_) async => const Right(_emptySettings));

      await cubit.load('acct-2');

      expect(cubit.state.accountId, 'acct-2');
      verify(mockGet('acct-2')).called(1);
      verifyNever(mockGet('acct-1'));
    });

    test('fills in default start/end dates for a mailbox with nothing '
        'scheduled', () async {
      when(mockGet('acct-1')).thenAnswer((_) async => const Right(_emptySettings));

      await cubit.load();

      final draft = cubit.state.draft!;
      expect(draft.start, isNotNull);
      expect(draft.end, isNotNull);
      // A week out by default.
      expect(draft.end!.difference(draft.start!).inDays, 7);
      // saved gets the same defaults as draft, so isDirty stays false until
      // the user actually changes something — the Save button doesn't read
      // as already-dirty on first load.
      expect(cubit.state.isDirty, isFalse);
    });

    test('keeps the mailbox\'s own dates when it already has a schedule',
        () async {
      final settings = OutOfOfficeSettings(
        enabled: true,
        start: DateTime(2026, 1, 1),
        end: DateTime(2026, 1, 5, 23, 59, 59),
      );
      when(mockGet('acct-1')).thenAnswer((_) async => Right(settings));

      await cubit.load();

      expect(cubit.state.draft!.start, DateTime(2026, 1, 1));
      expect(cubit.state.draft!.end, DateTime(2026, 1, 5, 23, 59, 59));
    });

    test('an UnsupportedFailure reports "unsupported", not "error"', () async {
      when(mockGet('acct-1')).thenAnswer((_) async =>
          const Left(UnsupportedFailure(message: 'IMAP has no such thing')));

      await cubit.load();

      expect(cubit.state.status, OutOfOfficeStatus.unsupported);
      expect(cubit.state.errorMessage, 'IMAP has no such thing');
    });

    test('any other failure reports "error"', () async {
      when(mockGet('acct-1'))
          .thenAnswer((_) async => const Left(ServerFailure(message: 'boom')));

      await cubit.load();

      expect(cubit.state.status, OutOfOfficeStatus.error);
      expect(cubit.state.errorMessage, 'boom');
    });

    test('needsPermission reflects the write-scope check', () async {
      when(mockAccountManager.hasOutOfOfficeWriteAccess('acct-1'))
          .thenAnswer((_) async => false);
      when(mockGet('acct-1')).thenAnswer((_) async => const Right(_emptySettings));

      await cubit.load();

      expect(cubit.state.needsPermission, isTrue);
    });

    test('a quiet reload that fails leaves the current state alone', () async {
      when(mockGet('acct-1')).thenAnswer((_) async => const Right(_emptySettings));
      await cubit.load();
      final before = cubit.state;

      when(mockGet('acct-1'))
          .thenAnswer((_) async => const Left(ServerFailure(message: 'boom')));
      await cubit.load('acct-1', true);

      expect(cubit.state.status, before.status);
      expect(cubit.state.draft, before.draft);
      expect(cubit.state.errorMessage, isNull);
    });
  });

  group('editing the draft', () {
    setUp(() async {
      when(mockGet('acct-1')).thenAnswer((_) async => const Right(_emptySettings));
      await cubit.load();
    });

    test('setEnabled flips the draft only', () {
      cubit.setEnabled(true);
      expect(cubit.state.draft!.enabled, isTrue);
      expect(cubit.state.isDirty, isTrue);
    });

    test('dragging the start date past the end pulls the end along', () {
      cubit.setEndDate(DateTime(2026, 3, 10));
      cubit.setStartDate(DateTime(2026, 3, 20));

      expect(cubit.state.draft!.start, DateTime(2026, 3, 20));
      // Pulled to the end of the new start day, not left before it.
      expect(cubit.state.draft!.end, DateTime(2026, 3, 20, 23, 59, 59));
    });

    test('setStartDate leaves a later end alone', () {
      cubit.setEndDate(DateTime(2026, 3, 20));
      cubit.setStartDate(DateTime(2026, 3, 10));

      expect(cubit.state.draft!.start, DateTime(2026, 3, 10));
      expect(cubit.state.draft!.end, DateTime(2026, 3, 20, 23, 59, 59));
    });

    test('setEndDate anchors to the end of the chosen day', () {
      cubit.setEndDate(DateTime(2026, 3, 20));
      expect(cubit.state.draft!.end, DateTime(2026, 3, 20, 23, 59, 59));
    });

    test('narrowing the audience to organisation-only switches off the '
        'separate external message but keeps its text', () {
      cubit.setExternalMessage('<p>Back Monday</p>');
      cubit.setUseSeparateExternalMessage(true);

      cubit.setAudience(OutOfOfficeAudience.organisationOnly);

      expect(cubit.state.draft!.useSeparateExternalMessage, isFalse);
      expect(cubit.state.draft!.externalMessageHtml, '<p>Back Monday</p>');
    });

    test('widening the audience again does not revive the option on its own',
        () {
      cubit.setUseSeparateExternalMessage(true);
      cubit.setAudience(OutOfOfficeAudience.organisationOnly);

      cubit.setAudience(OutOfOfficeAudience.everyone);

      expect(cubit.state.draft!.useSeparateExternalMessage, isFalse);
    });

    test('setMessageFor routes to the right body', () {
      cubit.setMessageFor(OutOfOfficeMessageSlot.internal, '<p>internal</p>');
      cubit.setMessageFor(OutOfOfficeMessageSlot.external, '<p>external</p>');

      expect(cubit.state.draft!.messageHtml, '<p>internal</p>');
      expect(cubit.state.draft!.externalMessageHtml, '<p>external</p>');
    });

    test('editing before anything has loaded does nothing', () async {
      // A fresh cubit that has never loaded: status defaults to `loading`
      // and there is no draft to edit yet.
      final fresh = OutOfOfficeCubit(
        getOutOfOffice: mockGet,
        setOutOfOffice: mockSet,
        accountManager: mockAccountManager,
      );
      addTearDown(fresh.close);

      fresh.setEnabled(true);

      expect(fresh.state.status, OutOfOfficeStatus.loading);
      expect(fresh.state.draft, isNull);
    });
  });

  group('requestPermission', () {
    setUp(() async {
      when(mockGet('acct-1')).thenAnswer((_) async => const Right(_emptySettings));
      await cubit.load();
    });

    test('a granted request clears needsPermission', () async {
      when(mockAccountManager.requestOutOfOfficeWriteAccess('acct-1'))
          .thenAnswer((_) async => true);

      final granted = await cubit.requestPermission();

      expect(granted, isTrue);
      expect(cubit.state.needsPermission, isFalse);
    });

    test('a declined request is not an error, and permission is still needed',
        () async {
      when(mockAccountManager.requestOutOfOfficeWriteAccess('acct-1'))
          .thenAnswer((_) async => false);

      final granted = await cubit.requestPermission();

      expect(granted, isFalse);
      expect(cubit.state.needsPermission, isTrue);
      expect(cubit.state.errorMessage, isNull);
    });

    test('an exception from the provider is reported as an error', () async {
      when(mockAccountManager.requestOutOfOfficeWriteAccess('acct-1'))
          .thenThrow(Exception('network down'));

      final granted = await cubit.requestPermission();

      expect(granted, isFalse);
      expect(cubit.state.errorMessage, contains('network down'));
    });
  });

  group('save', () {
    setUp(() async {
      when(mockGet('acct-1')).thenAnswer((_) async => const Right(_emptySettings));
      await cubit.load();
    });

    test('a successful save stamps savedAt and re-reads quietly', () async {
      cubit.setEnabled(true);
      cubit.setMessage('<p>Away</p>');
      when(mockSet(any)).thenAnswer((_) async => const Right(unit));
      when(mockGet('acct-1')).thenAnswer((_) async => Right(cubit.state.draft!));

      await cubit.save();

      expect(cubit.state.saving, isFalse);
      expect(cubit.state.savedAt, isNotNull);
      expect(cubit.state.saved, isNotNull);
      verify(mockSet(any)).called(1);
    });

    test('a failed save reports the error and clears the saving flag',
        () async {
      cubit.setEnabled(true);
      cubit.setMessage('<p>Away</p>');
      when(mockSet(any))
          .thenAnswer((_) async => const Left(ServerFailure(message: 'nope')));

      await cubit.save();

      expect(cubit.state.saving, isFalse);
      expect(cubit.state.errorMessage, 'nope');
      expect(cubit.state.savedAt, isNull);
    });

    test('does nothing when the draft cannot be saved (empty message while '
        'enabled)', () async {
      cubit.setEnabled(true);

      await cubit.save();

      verifyNever(mockSet(any));
    });
  });
}
