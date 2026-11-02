import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/presentation/widgets/forward_as_attachment.dart';

Email _email(String id, String subject) => Email(
      id: id,
      subject: subject,
      from: const EmailAddress(address: 'ada@example.com', name: 'Ada'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime(2026, 11, 3, 9),
      importance: EmailImportance.normal,
    );

Uint8List _raw(String id) => Uint8List.fromList(utf8.encode('source of $id'));

Future<Either<Failure, Uint8List>> _fetchOk(String id) async => Right(_raw(id));

void main() {
  group('gatherForwardAttachments', () {
    test('one message: attached as its .eml, and the subject is Fwd: it',
        () async {
      final result = await gatherForwardAttachments(
          [_email('m1', 'Quarterly numbers')], _fetchOk);

      final draft = result.getOrElse((l) => fail('expected a draft, got $l'));
      expect(draft.subject, 'Fwd: Quarterly numbers');
      expect(draft.attachments, hasLength(1));
      final att = draft.attachments.single;
      expect(att.name, 'Quarterly numbers.eml');
      expect(att.mimeType, 'message/rfc822');
      expect(att.bytes, _raw('m1'));
      expect(att.isInline, isFalse);
    });

    test('several messages: no subject, attachments in selection order',
        () async {
      final emails = [
        for (var i = 1; i <= 6; i++) _email('m$i', 'Subject $i'),
      ];
      final result = await gatherForwardAttachments(emails, _fetchOk);

      final draft = result.getOrElse((l) => fail('expected a draft, got $l'));
      expect(draft.subject, isNull);
      expect(draft.attachments.map((a) => a.name), [
        for (var i = 1; i <= 6; i++) 'Subject $i.eml',
      ]);
      expect(draft.attachments.map((a) => utf8.decode(a.bytes)), [
        for (var i = 1; i <= 6; i++) 'source of m$i',
      ]);
    });

    test('messages sharing a subject get distinct file names', () async {
      final result = await gatherForwardAttachments([
        _email('m1', 'Re: Meeting'),
        _email('m2', 'Re: Meeting'),
        _email('m3', 'Re: Meeting'),
      ], _fetchOk);

      final draft = result.getOrElse((l) => fail('expected a draft, got $l'));
      expect(draft.attachments.map((a) => a.name),
          ['Re_ Meeting.eml', 'Re_ Meeting (2).eml', 'Re_ Meeting (3).eml']);
    });

    test('any failed fetch answers its message and no draft', () async {
      final result = await gatherForwardAttachments(
        [_email('m1', 'A'), _email('m2', 'B'), _email('m3', 'C')],
        (id) async => id == 'm2'
            ? const Left(NetworkFailure(message: 'No connection'))
            : Right(_raw(id)),
      );

      expect(result.getLeft().toNullable(), 'No connection');
    });

    test('fetches at most batchSize at a time, and stops at a failed batch',
        () async {
      var inFlight = 0;
      var peak = 0;
      final asked = <String>[];
      Future<Either<Failure, Uint8List>> fetch(String id) async {
        asked.add(id);
        inFlight++;
        peak = inFlight > peak ? inFlight : peak;
        await Future<void>.delayed(Duration.zero);
        inFlight--;
        return id == 'm2'
            ? const Left(ServerFailure(message: 'Gone'))
            : Right(_raw(id));
      }

      final result = await gatherForwardAttachments(
        [for (var i = 1; i <= 10; i++) _email('m$i', 'S$i')],
        fetch,
        batchSize: 4,
      );

      expect(result.isLeft(), isTrue);
      expect(peak, 4);
      expect(asked, ['m1', 'm2', 'm3', 'm4'],
          reason: 'nothing past the batch that failed is downloaded');
    });
  });

  group('emlFileName', () {
    test('replaces characters a file system rejects', () {
      expect(emlFileName(r'a/b\c:d*e?f"g<h>i|j', {}), 'a_b_c_d_e_f_g_h_i_j.eml');
    });

    test('a subject that folds onto two lines stays one name', () {
      expect(emlFileName('Long\r\n subject', {}), 'Long__ subject.eml');
    });

    test('an empty or blank subject is "message"', () {
      final used = <String>{};
      expect(emlFileName('', used), 'message.eml');
      expect(emlFileName('   ', used), 'message (2).eml');
    });

    test('is capped at 80 characters before the extension', () {
      final name = emlFileName('x' * 200, {});
      expect(name, '${'x' * 80}.eml');
    });
  });
}
