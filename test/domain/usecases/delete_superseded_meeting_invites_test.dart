import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';
import 'package:nightmail/domain/repositories/email_repository.dart';
import 'package:nightmail/domain/usecases/delete_superseded_meeting_invites.dart';

const _account = 'acct-1';
const _inbox = 'INBOX';
const _organizer = EmailAddress(address: 'Bob@example.com', name: 'Bob');
const _other = EmailAddress(address: 'carol@example.com');

Email _email(
  String id, {
  required DateTime received,
  EmailAddress from = _organizer,
  String? conversationId,
  String? folderId = _inbox,
  List<String>? folderIds,
  MeetingInvite? invite,
  String body = '',
  bool isRead = true,
}) {
  return Email(
    id: id,
    subject: 'Invitation: Planning',
    from: from,
    toRecipients: const [EmailAddress(address: 'me@example.com')],
    ccRecipients: const [],
    bodyPreview: '',
    body: body,
    bodyType: EmailBodyType.text,
    isRead: isRead,
    receivedDateTime: received,
    importance: EmailImportance.normal,
    conversationId: conversationId,
    parentFolderId: folderId,
    folderIds: folderIds ?? (folderId == null ? const [] : [folderId]),
    meetingInvite: invite,
  );
}

MeetingInvite _invite({
  String? uid,
  MeetingEmailType type = MeetingEmailType.invitation,
}) => MeetingInvite(uid: uid, type: type, icsData: uid == null ? null : 'ics');

/// The repository as the use case sees it: a folder's list rows (invite
/// unknown), the full copy `getEmail` returns per id, and a log of deletes.
class _FakeEmailRepository implements EmailRepository {
  _FakeEmailRepository({
    required this.listRows,
    required this.fullCopies,
    this.unreadableIds = const {},
    this.listFailure,
  });

  final List<Email> listRows;
  final Map<String, Email> fullCopies;
  final Set<String> unreadableIds;
  final Failure? listFailure;

  final List<String> readIds = [];
  final List<(String, String?)> deleted = [];
  final List<(String, String)> cacheReads = [];

  @override
  Future<Either<Failure, List<Email>>> getCachedEmails({
    required String accountId,
    required String folderId,
  }) async {
    cacheReads.add((accountId, folderId));
    final failure = listFailure;
    if (failure != null) return Left(failure);
    return Right(listRows);
  }

  @override
  Future<Either<Failure, Email>> getEmail(String id) async {
    readIds.add(id);
    if (unreadableIds.contains(id)) {
      return const Left(ServerFailure(message: 'boom'));
    }
    final full = fullCopies[id];
    if (full == null) return const Left(ServerFailure(message: '404'));
    return Right(full);
  }

  @override
  Future<Either<Failure, Unit>> deleteEmail(
    String id, {
    String? accountId,
  }) async {
    deleted.add((id, accountId));
    return const Right(unit);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  final t0 = DateTime.utc(2026, 9, 21, 9);
  final t1 = DateTime.utc(2026, 9, 22, 9);
  final t2 = DateTime.utc(2026, 9, 23, 9);

  group('DeleteSupersededMeetingInvites', () {
    test('Gmail: deletes older invitations sharing the ICS UID even in another '
        'thread, and leaves other meetings from the same organizer', () async {
      final answered = _email(
        'new',
        received: t2,
        conversationId: 'thread-new',
        invite: _invite(uid: 'abc123@google.com'),
        body: 'x',
      );
      // Google files each expanded instance under <uid>_<start>@google.com.
      final older = _email('old', received: t1, conversationId: 'thread-old');
      final olderFull = _email(
        'old',
        received: t1,
        conversationId: 'thread-old',
        invite: _invite(uid: 'abc123_20260921T090000Z@google.com'),
        body: 'x',
        isRead: false,
      );
      final otherMeeting = _email('other', received: t0);
      final otherMeetingFull = _email(
        'other',
        received: t0,
        invite: _invite(uid: 'zzz999@google.com'),
        body: 'x',
      );
      final plainMail = _email('plain', received: t0);
      final plainMailFull = _email('plain', received: t0, body: 'hello');

      final repo = _FakeEmailRepository(
        listRows: [answered, older, otherMeeting, plainMail],
        fullCopies: {
          'old': olderFull,
          'other': otherMeetingFull,
          'plain': plainMailFull,
        },
      );

      final result = await DeleteSupersededMeetingInvites(repo)(
        DeleteSupersededMeetingInvitesParams(
          answered: answered,
          accountId: _account,
        ),
      );

      expect(result.isRight(), isTrue);
      final deleted = result.getOrElse((_) => []);
      expect(deleted.map((e) => e.id), ['old']);
      // The deleted copy is the full one, so the caller sees its read state.
      expect(deleted.single.isRead, isFalse);
      expect(repo.deleted, [('old', _account)]);
      expect(repo.cacheReads, [(_account, _inbox)]);
      // The answered message itself is never re-read.
      expect(repo.readIds, isNot(contains('new')));
    });

    test('never deletes a newer invitation to the same meeting', () async {
      final answered = _email(
        'mid',
        received: t1,
        invite: _invite(uid: 'abc@google.com'),
        body: 'x',
      );
      final newer = _email('newer', received: t2);
      final repo = _FakeEmailRepository(
        listRows: [answered, newer],
        fullCopies: {
          'newer': _email(
            'newer',
            received: t2,
            invite: _invite(uid: 'abc@google.com'),
            body: 'x',
          ),
        },
      );

      await DeleteSupersededMeetingInvites(repo)(
        DeleteSupersededMeetingInvitesParams(
          answered: answered,
          accountId: _account,
        ),
      );

      expect(repo.readIds, isEmpty);
      expect(repo.deleted, isEmpty);
    });

    test('Graph: with no UIDs, deletes older invitations in the same '
        'conversation only', () async {
      final answered = _email(
        'new',
        received: t2,
        conversationId: 'conv-1',
        invite: _invite(),
        body: 'x',
      );
      final sameConv = _email('same', received: t1, conversationId: 'conv-1');
      final sameConvFull = _email(
        'same',
        received: t1,
        conversationId: 'conv-1',
        invite: _invite(),
        body: 'x',
      );
      // Same organizer, a different meeting: read, then left alone — without
      // a UID the conversation is the only thing that says "same meeting".
      final otherConv = _email('diff', received: t1, conversationId: 'conv-2');
      final otherConvFull = _email(
        'diff',
        received: t1,
        conversationId: 'conv-2',
        invite: _invite(),
        body: 'x',
      );
      // An accepted-notification in the thread is not an invitation.
      final reply = _email('reply', received: t0, conversationId: 'conv-1');
      final replyFull = _email(
        'reply',
        received: t0,
        conversationId: 'conv-1',
        invite: _invite(type: MeetingEmailType.responseNotification),
        body: 'x',
      );

      final repo = _FakeEmailRepository(
        listRows: [answered, sameConv, otherConv, reply],
        fullCopies: {
          'same': sameConvFull,
          'diff': otherConvFull,
          'reply': replyFull,
        },
      );

      final result = await DeleteSupersededMeetingInvites(repo)(
        DeleteSupersededMeetingInvitesParams(
          answered: answered,
          accountId: _account,
        ),
      );

      expect(result.getOrElse((_) => []).map((e) => e.id), ['same']);
    });

    test('a cancellation tidies away the invitations to the meeting', () async {
      final cancellation = _email(
        'cancel',
        received: t2,
        invite: _invite(
          uid: 'abc@google.com',
          type: MeetingEmailType.cancellation,
        ),
        body: 'x',
      );
      final invite = _email('inv', received: t1);
      final repo = _FakeEmailRepository(
        listRows: [cancellation, invite],
        fullCopies: {
          'inv': _email(
            'inv',
            received: t1,
            invite: _invite(uid: 'abc@google.com'),
            body: 'x',
          ),
        },
      );

      final result = await DeleteSupersededMeetingInvites(repo)(
        DeleteSupersededMeetingInvitesParams(
          answered: cancellation,
          accountId: _account,
        ),
      );

      expect(result.getOrElse((_) => []).map((e) => e.id), ['inv']);
    });

    test('ignores rows from other senders and other folders', () async {
      final answered = _email(
        'new',
        received: t2,
        conversationId: 'conv-new',
        invite: _invite(uid: 'abc@google.com'),
        body: 'x',
      );
      // Same UID, but forwarded by somebody else in an unrelated thread — not
      // plausibly an earlier copy of this invitation, so never even read.
      final fromElsewhere = _email(
        'fwd',
        received: t1,
        from: _other,
        conversationId: 'conv-fwd',
      );
      // Listed under the Inbox as thread context, but physically in Archive.
      final archived = _email(
        'archived',
        received: t1,
        folderId: 'ARCHIVE',
        folderIds: const ['ARCHIVE'],
      );
      final repo = _FakeEmailRepository(
        listRows: [answered, fromElsewhere, archived],
        fullCopies: {
          for (final id in ['fwd', 'archived'])
            id: _email(
              id,
              received: t1,
              invite: _invite(uid: 'abc@google.com'),
              body: 'x',
            ),
        },
      );

      await DeleteSupersededMeetingInvites(repo)(
        DeleteSupersededMeetingInvitesParams(
          answered: answered,
          accountId: _account,
        ),
      );

      expect(repo.readIds, isEmpty);
      expect(repo.deleted, isEmpty);
    });

    test('a candidate that cannot be read is skipped, not fatal', () async {
      final answered = _email(
        'new',
        received: t2,
        invite: _invite(uid: 'abc@google.com'),
        body: 'x',
      );
      final broken = _email('broken', received: t1);
      final good = _email('good', received: t0);
      final repo = _FakeEmailRepository(
        listRows: [answered, broken, good],
        unreadableIds: {'broken'},
        fullCopies: {
          'good': _email(
            'good',
            received: t0,
            invite: _invite(uid: 'abc@google.com'),
            body: 'x',
          ),
        },
      );

      final result = await DeleteSupersededMeetingInvites(repo)(
        DeleteSupersededMeetingInvitesParams(
          answered: answered,
          accountId: _account,
        ),
      );

      expect(result.getOrElse((_) => []).map((e) => e.id), ['good']);
    });

    test('reads newest candidates first and stops at the cap', () async {
      final answered = _email(
        'new',
        received: t2,
        invite: _invite(uid: 'abc@google.com'),
        body: 'x',
      );
      final rows = [
        for (
          var i = 0;
          i < DeleteSupersededMeetingInvites.maxCandidates + 5;
          i++
        )
          _email('c$i', received: t0.add(Duration(minutes: i))),
      ];
      final repo = _FakeEmailRepository(
        listRows: [answered, ...rows],
        fullCopies: {
          for (final r in rows)
            r.id: _email(r.id, received: r.receivedDateTime, body: 'x'),
        },
      );

      await DeleteSupersededMeetingInvites(repo)(
        DeleteSupersededMeetingInvitesParams(
          answered: answered,
          accountId: _account,
        ),
      );

      expect(repo.readIds.length, DeleteSupersededMeetingInvites.maxCandidates);
      expect(repo.readIds.first, 'c${rows.length - 1}');
      expect(repo.readIds, isNot(contains('c0')));
    });

    test(
      'does nothing without a folder or an invite on the answered message',
      () async {
        final repo = _FakeEmailRepository(listRows: [], fullCopies: {});
        final useCase = DeleteSupersededMeetingInvites(repo);

        await useCase(
          DeleteSupersededMeetingInvitesParams(
            answered: _email(
              'a',
              received: t2,
              folderId: null,
              invite: _invite(),
            ),
            accountId: _account,
          ),
        );
        await useCase(
          DeleteSupersededMeetingInvitesParams(
            answered: _email('b', received: t2),
            accountId: _account,
          ),
        );

        expect(repo.cacheReads, isEmpty);
      },
    );

    test('a cache failure is reported', () async {
      final repo = _FakeEmailRepository(
        listRows: [],
        fullCopies: {},
        listFailure: const CacheFailure(message: 'locked'),
      );

      final result = await DeleteSupersededMeetingInvites(repo)(
        DeleteSupersededMeetingInvitesParams(
          answered: _email(
            'a',
            received: t2,
            invite: _invite(uid: 'u'),
          ),
          accountId: _account,
        ),
      );

      expect(result.isLeft(), isTrue);
    });
  });
}
