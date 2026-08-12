import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource.dart';
import 'package:nightmail/data/datasources/remote/email_remote_datasource.dart';
import 'package:nightmail/data/models/email_address_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/infrastructure/sync/body_prefetch_service.dart';

const _accountId = 'acct-1';

EmailModel _email(
  String id, {
  String body = '',
  String folderId = 'INBOX',
  bool isRead = false,
}) =>
    EmailModel(
      id: id,
      subject: 'Subject $id',
      from: const EmailAddressModel(address: 'a@b.com'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: body,
      bodyType: EmailBodyType.text,
      isRead: isRead,
      receivedDateTime: DateTime(2026, 6, 1),
      importance: EmailImportance.normal,
      parentFolderId: folderId,
    );

/// In-memory stand-in: records cache writes and answers by-id lookups from a
/// preset map so tests control what is "already cached" per message.
class _FakeLocal extends Fake implements EmailLocalDatasource {
  final Map<String, Email> cached = {};
  final List<Email> writes = [];

  @override
  Future<Email?> getCachedEmailById({
    required String accountId,
    required String emailId,
  }) async =>
      cached[emailId];

  /// Mirrors the real implementation's two load-bearing properties: the row
  /// lookup and the write are one atomic step, and a row that has gone is not
  /// re-inserted. [cacheEmails] is deliberately left unimplemented — `Fake`
  /// throws on it, so going back to an inserting write fails these tests.
  ///
  /// It takes no folder: an upgrade lands on the message wherever it is already
  /// cached and never files it anywhere new. Which folders those are is the
  /// cache's business, exercised against a real database in
  /// `email_local_datasource_impl_test.dart`.
  @override
  Future<void> upgradeCachedEmailBody({
    required String accountId,
    required Email email,
  }) async {
    final row = cached[email.id];
    if (row == null) return;
    final merged = email.copyWith(isRead: row.isRead);
    cached[email.id] = merged;
    writes.add(merged);
  }
}

/// Serves a full copy per id, or a thrower / a hang-until-released future for
/// the concurrency and error tests.
class _FakeRemote extends Fake implements EmailRemoteDatasource {
  final Map<String, EmailModel> full = {};
  final Set<String> throwFor = {};
  final Map<String, Completer<EmailModel>> gate = {};
  final List<String> getEmailCalls = [];

  @override
  Future<EmailModel> getEmail(String id) {
    getEmailCalls.add(id);
    if (throwFor.contains(id)) {
      throw StateError('boom for $id');
    }
    final blocker = gate[id];
    if (blocker != null) return blocker.future;
    return Future.value(full[id] ?? _email(id, body: 'FULL $id'));
  }
}

void main() {
  late _FakeLocal local;
  late _FakeRemote remote;
  late BodyPrefetchService service;

  setUp(() {
    local = _FakeLocal();
    remote = _FakeRemote();
    service = BodyPrefetchService(localDatasource: local);
  });

  Future<void> run(List<Email> emails) => service.prefetchBodies(
        accountId: _accountId,
        datasource: remote,
        emails: emails,
      );

  test('fetches and caches a full body for a body-less, still-cached message',
      () async {
    local.cached['m1'] = _email('m1'); // thin row present in cache
    remote.full['m1'] = _email('m1', body: 'HELLO', folderId: 'INBOX');

    await run([_email('m1')]);

    expect(remote.getEmailCalls, ['m1']);
    expect(local.cached['m1']!.body, 'HELLO');
    expect(local.writes.single.id, 'm1');
  });

  test('preserves the cached read state over the freshly-fetched one',
      () async {
    // Thin row carries an optimistic mark-as-read that hasn't drained yet.
    local.cached['m1'] = _email('m1', isRead: true);
    // Server still reports it unread.
    remote.full['m1'] = _email('m1', body: 'HELLO', isRead: false);

    await run([_email('m1')]);

    expect(local.cached['m1']!.body, 'HELLO'); // body upgraded
    expect(local.cached['m1']!.isRead, isTrue); // local read state kept
  });

  test('skips a message whose cached row already has a body', () async {
    local.cached['m1'] = _email('m1', body: 'ALREADY');

    // The candidate as delivered by sync is still body-less...
    await run([_email('m1')]);

    // ...but the cache says it is already full, so no fetch happens.
    expect(remote.getEmailCalls, isEmpty);
    expect(local.writes, isEmpty);
  });

  test('skips a message that has vanished from the cache (deleted/moved)',
      () async {
    // Nothing in local.cached for m1 → getCachedEmailById returns null.
    await run([_email('m1')]);

    expect(remote.getEmailCalls, isEmpty);
    expect(local.writes, isEmpty); // never resurrected
  });

  // The prefetch runs for one folder but the message it upgrades may be listed
  // in several, so the write is addressed to the message alone — the folder
  // this used to carry is exactly what re-filed the row and emptied another
  // folder's cache of it.
  test('upgrades a message whose full copy names no parent folder', () async {
    local.cached['m1'] = _email('m1');
    remote.full['m1'] = _email('m1', body: 'X').copyWithParent(null);

    await run([_email('m1')]);

    expect(local.writes.single.body, 'X');
  });

  test('caps the batch at 20 messages', () async {
    final candidates = <Email>[];
    for (var i = 0; i < 25; i++) {
      final id = 'm$i';
      local.cached[id] = _email(id);
      candidates.add(_email(id));
    }

    await run(candidates);

    expect(remote.getEmailCalls, hasLength(20));
  });

  test('swallows a per-message failure and continues with the rest', () async {
    for (final id in ['a', 'b', 'c']) {
      local.cached[id] = _email(id);
    }
    remote.throwFor.add('b');
    remote.full['a'] = _email('a', body: 'A');
    remote.full['c'] = _email('c', body: 'C');

    await run([_email('a'), _email('b'), _email('c')]);

    expect(remote.getEmailCalls, ['a', 'b', 'c']);
    expect(local.cached['a']!.body, 'A');
    expect(local.cached['c']!.body, 'C');
    expect(local.cached['b']!.body, isEmpty); // failed one left thin
  });

  // The pre-fetch check cannot cover this: it ran before the round-trip, and the
  // message the prefetch is upgrading is the one the user is most likely reading
  // — and deleting — while it is in flight. Before the write became a
  // present-row-only upgrade, this put the message back in the folder, and the
  // outbox's tombstone could not veto it because the write bypassed the
  // repository entirely.
  test('does not resurrect a message deleted while its body was in flight',
      () async {
    local.cached['m1'] = _email('m1');
    final gate = Completer<EmailModel>();
    remote.gate['m1'] = gate;

    final inFlight = run([_email('m1')]);
    await Future<void>.delayed(Duration.zero);

    // The user deletes it: the repository drops the cache row before the body
    // comes back.
    local.cached.remove('m1');

    gate.complete(_email('m1', body: 'FULL'));
    await inFlight;

    expect(remote.getEmailCalls, ['m1'], reason: 'the fetch had already gone');
    expect(local.writes, isEmpty);
    expect(local.cached.containsKey('m1'), isFalse);
  });

  test('drops a concurrent second batch for the same account', () async {
    local.cached['m1'] = _email('m1');
    final gate = Completer<EmailModel>();
    remote.gate['m1'] = gate;

    // First batch starts and blocks inside getEmail('m1').
    final first = run([_email('m1')]);
    await Future<void>.delayed(Duration.zero);

    // Second batch while the first is in flight — must no-op immediately.
    await run([_email('m1')]);
    expect(remote.getEmailCalls, ['m1']); // still just the first fetch

    gate.complete(_email('m1', body: 'DONE'));
    await first;
    expect(local.cached['m1']!.body, 'DONE');
  });
}

extension _CopyParent on EmailModel {
  /// Rebuilds the model with a different (or null) parent folder — the entity's
  /// own copyWith only takes isRead, so tests need this to exercise the
  /// null-parent fallback.
  EmailModel copyWithParent(String? parentFolderId) => EmailModel(
        id: id,
        subject: subject,
        from: EmailAddressModel(address: from.address, name: from.name),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: bodyPreview,
        body: body,
        bodyType: bodyType,
        isRead: isRead,
        receivedDateTime: receivedDateTime,
        importance: importance,
        parentFolderId: parentFolderId,
      );
}
