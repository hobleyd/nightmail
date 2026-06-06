import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/repositories/email_repository.dart';
import 'package:nightmail/domain/usecases/get_emails.dart';

import 'get_emails_test.mocks.dart';

@GenerateMocks([EmailRepository])
void main() {
  late GetEmails useCase;
  late MockEmailRepository mockRepository;

  setUp(() {
    // Mockito cannot auto-generate dummy values for sealed/abstract types like
    // Either, so we register one explicitly.
    provideDummy<Either<Failure, List<Email>>>(const Right([]));
    provideDummy<Either<Failure, Email>>(Right(Email(
      id: '',
      subject: '',
      from: const EmailAddress(address: ''),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: false,
      receivedDateTime: DateTime(2026),
      importance: EmailImportance.normal,
    )));
    mockRepository = MockEmailRepository();
    useCase = GetEmails(mockRepository);
  });

  final tEmails = [
    Email(
      id: 'email-1',
      subject: 'Test Email',
      from: const EmailAddress(address: 'sender@example.com', name: 'Sender'),
      toRecipients: const [
        EmailAddress(address: 'recipient@example.com'),
      ],
      ccRecipients: const [],
      bodyPreview: 'Preview text',
      body: 'Full body',
      bodyType: EmailBodyType.text,
      isRead: false,
      receivedDateTime: DateTime(2026, 6, 1),
      importance: EmailImportance.normal,
    ),
  ];

  group('GetEmails', () {
    test('returns emails on repository success', () async {
      when(mockRepository.getEmails(
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        orderBy: anyNamed('orderBy'),
      )).thenAnswer((_) async => Right(tEmails));

      final result = await useCase(const GetEmailsParams());

      expect(result, Right(tEmails));
      verify(mockRepository.getEmails(
        top: 25,
        skip: 0,
        orderBy: 'receivedDateTime desc',
      ));
      verifyNoMoreInteractions(mockRepository);
    });

    test('forwards folder ID to repository', () async {
      when(mockRepository.getEmails(
        folderId: anyNamed('folderId'),
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        orderBy: anyNamed('orderBy'),
      )).thenAnswer((_) async => Right(tEmails));

      await useCase(const GetEmailsParams(folderId: 'inbox-folder-id'));

      verify(mockRepository.getEmails(
        folderId: 'inbox-folder-id',
        top: 25,
        skip: 0,
        orderBy: 'receivedDateTime desc',
      ));
    });

    test('returns failure when repository fails', () async {
      const failure = ServerFailure(message: 'Graph API error');
      when(mockRepository.getEmails(
        top: anyNamed('top'),
        skip: anyNamed('skip'),
        orderBy: anyNamed('orderBy'),
      )).thenAnswer((_) async => const Left(failure));

      final result = await useCase(const GetEmailsParams());

      expect(result, const Left(failure));
    });
  });
}
