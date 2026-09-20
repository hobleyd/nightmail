// The shape of a meeting's reminder series: the lead-time alert, a five-minute
// countdown over the last quarter hour, and a final alert at the start itself.
// This is the one part of NotificationService that is testable without a
// platform channel behind it, and it is the part that decides how many alerts
// each event costs the OS scheduler — so the bound on long lead times is
// covered as deliberately as the ladder is.

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/usecases/delete_email.dart';
import 'package:nightmail/domain/usecases/mark_email_as_read.dart';
import 'package:nightmail/infrastructure/notifications/notification_service.dart';
import 'package:nightmail/injection_container.dart';

import 'notification_service_test.mocks.dart';

@GenerateMocks([MarkEmailAsRead, DeleteEmail])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reminderOffsets', () {
    test('counts down in five-minute steps and ends at the start', () {
      expect(NotificationService.reminderOffsets(15), [15, 10, 5, 0]);
    });

    test('keeps the lead-time alert when it is not on the five-minute grid', () {
      expect(NotificationService.reminderOffsets(7), [7, 5, 0]);
      expect(NotificationService.reminderOffsets(3), [3, 0]);
    });

    test('a lead time inside one step is just the alert and the start', () {
      expect(NotificationService.reminderOffsets(5), [5, 0]);
    });

    test('"at the time of the event" is a single final alert', () {
      expect(NotificationService.reminderOffsets(0), [0]);
    });

    test('a longer lead time alerts when asked, then counts down from 15', () {
      expect(NotificationService.reminderOffsets(30), [30, 15, 10, 5, 0]);
      expect(NotificationService.reminderOffsets(60), [60, 15, 10, 5, 0]);
    });

    test('a day-ahead lead time is five alerts, not 289', () {
      final day = NotificationService.reminderOffsets(1440);

      expect(day, [1440, 15, 10, 5, 0]);
    });

    test('every series is ordered, distinct, and finishes at zero', () {
      for (final leadTime in [0, 5, 10, 15, 30, 60, 120, 360, 720, 1440]) {
        final offsets = NotificationService.reminderOffsets(leadTime);
        expect(offsets.last, 0, reason: 'lead time $leadTime has no final alert');
        expect(offsets.toSet().length, offsets.length,
            reason: 'lead time $leadTime repeats an offset');
        expect(
          offsets,
          orderedEquals(offsets.toList()..sort((a, b) => b.compareTo(a))),
          reason: 'lead time $leadTime is out of order',
        );
        expect(offsets.length, lessThanOrEqualTo(5),
            reason: 'lead time $leadTime would flood the OS scheduler');
      }
    });
  });

  group('handleMailAction', () {
    late NotificationService service;
    late MockMarkEmailAsRead mockMarkEmailAsRead;
    late MockDeleteEmail mockDeleteEmail;

    final tEmail = Email(
      id: 'email-1',
      subject: 'Test',
      from: EmailAddress(address: 'a@b.com'),
      toRecipients: [],
      ccRecipients: [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime.utc(2026, 1, 1),
      importance: EmailImportance.normal,
    );

    setUp(() {
      provideDummy<Either<Failure, Email>>(Right(tEmail));
      provideDummy<Either<Failure, Unit>>(const Right(unit));
      mockMarkEmailAsRead = MockMarkEmailAsRead();
      mockDeleteEmail = MockDeleteEmail();
      sl.registerLazySingleton<MarkEmailAsRead>(() => mockMarkEmailAsRead);
      sl.registerLazySingleton<DeleteEmail>(() => mockDeleteEmail);
      service = NotificationService();
    });

    tearDown(() async => sl.reset());

    test('MARK_READ calls MarkEmailAsRead with the notification\'s '
        'account, not the active one', () async {
      when(mockMarkEmailAsRead(any))
          .thenAnswer((_) async => Right(tEmail));

      await service.handleMailAction(
        actionId: NotificationService.markReadActionId,
        emailId: 'email-1',
        accountId: 'account-2',
      );

      final params =
          verify(mockMarkEmailAsRead(captureAny)).captured.single
              as MarkEmailAsReadParams;
      expect(params.id, 'email-1');
      expect(params.isRead, isTrue);
      expect(params.accountId, 'account-2');
      verifyNever(mockDeleteEmail(any));
    });

    test('DELETE calls DeleteEmail with the notification\'s account',
        () async {
      when(mockDeleteEmail(any)).thenAnswer((_) async => const Right(unit));

      await service.handleMailAction(
        actionId: NotificationService.deleteActionId,
        emailId: 'email-1',
        accountId: 'account-2',
      );

      final params =
          verify(mockDeleteEmail(captureAny)).captured.single
              as DeleteEmailParams;
      expect(params.id, 'email-1');
      expect(params.accountId, 'account-2');
      verifyNever(mockMarkEmailAsRead(any));
    });

    test('DISMISS calls neither use case', () async {
      await service.handleMailAction(
        actionId: NotificationService.dismissActionId,
        emailId: 'email-1',
        accountId: 'account-2',
      );

      verifyNever(mockMarkEmailAsRead(any));
      verifyNever(mockDeleteEmail(any));
    });
  });
}
