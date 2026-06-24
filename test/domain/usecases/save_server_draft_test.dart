import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/local_attachment.dart';
import 'package:nightmail/domain/repositories/email_repository.dart';
import 'package:nightmail/domain/usecases/save_server_draft.dart';

import 'save_server_draft_test.mocks.dart';

@GenerateMocks([EmailRepository])
void main() {
  late SaveServerDraft useCase;
  late MockEmailRepository mockRepository;

  setUp(() {
    provideDummy<Either<Failure, String>>(const Right(''));
    mockRepository = MockEmailRepository();
    useCase = SaveServerDraft(mockRepository);
  });

  group('SaveServerDraft — create new draft', () {
    test('calls createServerDraft when no existingDraftId', () async {
      when(mockRepository.createServerDraft(
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
      )).thenAnswer((_) async => const Right('new-draft-id'));

      final result = await useCase(const SaveServerDraftParams(
        toAddresses: ['to@example.com'],
        subject: 'Hello',
        body: 'Draft body',
      ));

      expect(result, const Right('new-draft-id'));
      verify(mockRepository.createServerDraft(
        toAddresses: ['to@example.com'],
        subject: 'Hello',
        body: 'Draft body',
      ));
      verifyNever(mockRepository.updateServerDraft(
        draftId: anyNamed('draftId'),
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
      ));
    });

    test('forwards bodyType to createServerDraft', () async {
      when(mockRepository.createServerDraft(
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
        bodyType: anyNamed('bodyType'),
      )).thenAnswer((_) async => const Right('draft-1'));

      await useCase(const SaveServerDraftParams(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: '<p>HTML body</p>',
        bodyType: EmailBodyType.html,
      ));

      verify(mockRepository.createServerDraft(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: '<p>HTML body</p>',
        bodyType: EmailBodyType.html,
      ));
    });

    test('forwards attachments to createServerDraft', () async {
      final attachment = LocalAttachment(
        name: 'file.pdf',
        mimeType: 'application/pdf',
        bytes: Uint8List(0),
      );
      when(mockRepository.createServerDraft(
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
        newAttachments: anyNamed('newAttachments'),
      )).thenAnswer((_) async => const Right('draft-2'));

      await useCase(SaveServerDraftParams(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: 'Body',
        newAttachments: [attachment],
      ));

      verify(mockRepository.createServerDraft(
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: 'Body',
        newAttachments: [attachment],
      ));
    });

    test('returns failure when createServerDraft fails', () async {
      const failure = ServerFailure(message: 'Draft creation failed');
      when(mockRepository.createServerDraft(
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
      )).thenAnswer((_) async => const Left(failure));

      final result = await useCase(const SaveServerDraftParams(
        toAddresses: [],
        subject: '',
        body: '',
      ));

      expect(result, const Left(failure));
    });
  });

  group('SaveServerDraft — update existing draft', () {
    test('calls updateServerDraft when existingDraftId is provided', () async {
      when(mockRepository.updateServerDraft(
        draftId: anyNamed('draftId'),
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
      )).thenAnswer((_) async => const Right('existing-draft-id'));

      final result = await useCase(const SaveServerDraftParams(
        existingDraftId: 'existing-draft-id',
        toAddresses: ['to@example.com'],
        subject: 'Updated Subject',
        body: 'Updated body',
      ));

      expect(result, const Right('existing-draft-id'));
      verify(mockRepository.updateServerDraft(
        draftId: 'existing-draft-id',
        toAddresses: ['to@example.com'],
        subject: 'Updated Subject',
        body: 'Updated body',
      ));
      verifyNever(mockRepository.createServerDraft(
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
      ));
    });

    test('forwards bodyType to updateServerDraft', () async {
      when(mockRepository.updateServerDraft(
        draftId: anyNamed('draftId'),
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
        bodyType: anyNamed('bodyType'),
      )).thenAnswer((_) async => const Right('draft-3'));

      await useCase(const SaveServerDraftParams(
        existingDraftId: 'draft-3',
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: '<p>HTML</p>',
        bodyType: EmailBodyType.html,
      ));

      verify(mockRepository.updateServerDraft(
        draftId: 'draft-3',
        toAddresses: ['to@example.com'],
        subject: 'Subject',
        body: '<p>HTML</p>',
        bodyType: EmailBodyType.html,
      ));
    });

    test('returns failure when updateServerDraft fails', () async {
      const failure = ServerFailure(message: 'Draft update failed');
      when(mockRepository.updateServerDraft(
        draftId: anyNamed('draftId'),
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
      )).thenAnswer((_) async => const Left(failure));

      final result = await useCase(const SaveServerDraftParams(
        existingDraftId: 'draft-id',
        toAddresses: [],
        subject: '',
        body: '',
      ));

      expect(result, const Left(failure));
    });
  });
}
