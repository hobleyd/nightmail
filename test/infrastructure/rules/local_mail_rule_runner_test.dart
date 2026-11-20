import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/local/mail_rule_store.dart';
import 'package:nightmail/data/datasources/remote/local_rule_mailbox.dart';
import 'package:nightmail/data/models/email_address_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/mail_rule.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/rules/local_mail_rule_runner.dart';

const _account = ImapAccount(
  id: 'imap-1',
  displayName: 'Me',
  emailAddress: 'me@example.com',
  host: 'imap.example.com',
  port: 993,
  useSsl: true,
  smtpHost: 'smtp.example.com',
  smtpPort: 587,
  smtpUseSsl: false,
);

EmailModel _msg(int uid, {String subject = 'Hello', String from = 'a@x.com'}) =>
    EmailModel(
      id: 'INBOX:$uid',
      subject: subject,
      from: EmailAddressModel(address: from),
      toRecipients: const [EmailAddressModel(address: 'me@example.com')],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: false,
      receivedDateTime: DateTime(2026, 11, 20),
      importance: EmailImportance.normal,
      hasAttachments: false,
    );

MailRule _rule(
  String id,
  int sequence,
  List<MailRuleAction> actions, {
  String subject = 'Hello',
}) => MailRule(
  id: id,
  name: id,
  sequence: sequence,
  conditions: [
    MailRuleCondition(MailRuleConditionKind.subjectContains, values: [subject]),
  ],
  actions: actions,
);

/// Records every call, and the saved progress at the moment of each one —
/// which is how "claimed before acted on" is checked.
class _FakeMailbox implements LocalRuleMailbox {
  _FakeMailbox(this.store);

  final MailRuleStore store;
  int? uidValidity = 1;
  int uidNext = 101;
  bool keywordsAllowed = false;
  List<EmailModel> inbox = [];
  final calls = <String>[];
  final progressAtCall = <String, int?>{};
  int? lastAfterUid;
  Set<String> autoSubmitted = {};
  Set<String> lostClaims = {};
  Map<String, int> modSequences = {};
  final claimedWith = <String, int?>{};

  /// Thrown by every call whose text starts with [failPrefix].
  Exception? failOn;
  String failPrefix = 'move';

  Future<void> _record(String call) async {
    calls.add(call);
    progressAtCall[call] = (await store.loadProgress(_account.id))?.lastUid;
    if (failOn != null && call.startsWith(failPrefix)) throw failOn!;
  }

  @override
  Future<InboxArrivals> fetchInboxArrivals({
    required int? afterUid,
    required int limit,
    String? excludeKeyword,
  }) async {
    lastAfterUid = afterUid;
    final messages = afterUid == null
        ? <EmailModel>[]
        : inbox
              .where((m) => int.parse(m.id.split(':').last) > afterUid)
              .take(limit)
              .toList();
    return InboxArrivals(
      uidValidity: uidValidity,
      uidNext: uidNext,
      keywordsAllowed: keywordsAllowed,
      messages: messages,
      modSequences: modSequences,
      autoSubmitted: autoSubmitted,
    );
  }

  @override
  Future<EmailModel> peekEmail(String id) async =>
      inbox.firstWhere((m) => m.id == id);

  @override
  Future<void> addFlags(String id, List<String> flags) =>
      _record('flag $id ${flags.join(' ')}');

  @override
  Future<void> copyEmail(String id, String destinationFolderId) =>
      _record('copy $id $destinationFolderId');

  @override
  Future<String?> moveEmail(String id, String destinationFolderId) async {
    await _record('move $id $destinationFolderId');
    return null;
  }

  @override
  Future<bool> claim(String id, String keyword, {int? unchangedSince}) async {
    claimedWith[id] = unchangedSince;
    await _record('claim $id $keyword');
    return !lostClaims.contains(id);
  }

  @override
  Future<void> trashEmail(String id) => _record('trash $id');

  @override
  Future<EmailModel> updateEmailReadStatus({
    required String id,
    required bool isRead,
  }) async {
    await _record('read $id');
    return inbox.firstWhere((m) => m.id == id);
  }

  @override
  Future<void> forwardForRule({
    required String messageId,
    required List<String> toAddresses,
    required String comment,
    required EmailBodyType bodyType,
  }) => _record('forward $messageId ${toAddresses.join(',')}');
}

void main() {
  late Directory dir;
  late MailRuleStore store;
  late _FakeMailbox mailbox;
  late LocalMailRuleRunner runner;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mail_rules_test');
    store = MailRuleStore(directory: () async => dir);
    mailbox = _FakeMailbox(store);
    runner = LocalMailRuleRunner(store: store);
  });

  tearDown(() => dir.delete(recursive: true));

  Future<void> withRules(List<MailRule> rules) =>
      store.saveRules(_account.id, rules);

  Future<void> atProgress(int lastUid, {int uidValidity = 1}) =>
      store.saveProgress(
        _account.id,
        MailRuleProgress(uidValidity: uidValidity, lastUid: lastUid),
      );

  test('switching rules on starts from the newest message, not from 0', () async {
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.delete)]),
    ]);
    mailbox.inbox = [_msg(50), _msg(100)];

    final result = await runner.run(_account, mailbox);

    // The whole existing Inbox matches "Hello"; none of it may be deleted.
    expect(mailbox.calls, isEmpty);
    expect(result.processed, 0);
    expect(mailbox.lastAfterUid, isNull);
    expect((await store.loadProgress(_account.id))!.lastUid, 100);
  });

  test('a rebuilt Inbox restarts from its newest message', () async {
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.delete)]),
    ]);
    await atProgress(40, uidValidity: 7);
    mailbox.inbox = [_msg(41), _msg(100)];

    await runner.run(_account, mailbox);

    expect(mailbox.calls, isEmpty);
    final progress = (await store.loadProgress(_account.id))!;
    expect(progress.uidValidity, 1);
    expect(progress.lastUid, 100);
  });

  test('no enabled rules forgets progress, so the next start is "now"', () async {
    await withRules([
      _rule('r', 1, const [
        MailRuleAction(MailRuleActionKind.delete),
      ]).copyWith(enabled: false),
    ]);
    await atProgress(40);

    await runner.run(_account, mailbox);

    expect(await store.loadProgress(_account.id), isNull);
  });

  test('each message is claimed before anything is done to it', () async {
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.markAsRead)]),
    ]);
    await atProgress(10);
    mailbox.inbox = [_msg(11), _msg(12)];

    await runner.run(_account, mailbox);

    expect(mailbox.progressAtCall['read INBOX:11'], 11);
    expect(mailbox.progressAtCall['read INBOX:12'], 12);
  });

  test('where the server keeps keywords the claim is on the message too', () async {
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.markAsRead)]),
    ]);
    await atProgress(10);
    mailbox
      ..keywordsAllowed = true
      ..inbox = [_msg(11)];

    await runner.run(_account, mailbox);

    expect(mailbox.calls, [
      'claim INBOX:11 ${LocalMailRuleRunner.claimKeyword}',
      'read INBOX:11',
    ]);
  });

  test('the claim is conditional on the MODSEQ the fetch saw', () async {
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.markAsRead)]),
    ]);
    await atProgress(10);
    mailbox
      ..keywordsAllowed = true
      ..modSequences = {'INBOX:11': 4242}
      ..inbox = [_msg(11)];

    await runner.run(_account, mailbox);

    expect(mailbox.claimedWith['INBOX:11'], 4242);
  });

  test('a message another device claimed first is left alone', () async {
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.markAsRead)]),
    ]);
    await atProgress(10);
    mailbox
      ..keywordsAllowed = true
      ..lostClaims = {'INBOX:11'}
      ..inbox = [_msg(11), _msg(12)];

    await runner.run(_account, mailbox);

    expect(mailbox.calls, [
      'claim INBOX:11 ${LocalMailRuleRunner.claimKeyword}',
      'claim INBOX:12 ${LocalMailRuleRunner.claimKeyword}',
      'read INBOX:12',
    ]);
  });

  test('a claim that fails ends the run rather than claiming the rest',
      () async {
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.markAsRead)]),
    ]);
    await atProgress(10);
    mailbox
      ..keywordsAllowed = true
      ..failOn = const ServerException(message: 'IMAP error')
      ..failPrefix = 'claim'
      ..inbox = [_msg(11), _msg(12)];

    await expectLater(
      runner.run(_account, mailbox),
      throwsA(isA<ServerException>()),
    );
    expect(mailbox.calls, ['claim INBOX:11 ${LocalMailRuleRunner.claimKeyword}']);
  });

  test('two failed actions in a row end the run', () async {
    // How a dropped connection usually surfaces: a plain IMAP error.
    await withRules([
      _rule('r', 1, const [
        MailRuleAction(MailRuleActionKind.moveToFolder, folderId: 'Archive'),
      ]),
    ]);
    await atProgress(10);
    mailbox
      ..failOn = const ServerException(message: 'IMAP error')
      ..inbox = [_msg(11), _msg(12), _msg(13)];

    await expectLater(
      runner.run(_account, mailbox),
      throwsA(isA<ServerException>()),
    );
    expect(mailbox.calls, ['move INBOX:11 Archive', 'move INBOX:12 Archive']);
    expect((await store.loadProgress(_account.id))!.lastUid, 12);
  });

  test('a move or copy into the Inbox is refused', () async {
    await withRules([
      _rule('r', 1, const [
        MailRuleAction(MailRuleActionKind.copyToFolder, folderId: 'inbox'),
        MailRuleAction(MailRuleActionKind.moveToFolder, folderId: 'INBOX'),
      ]),
    ]);
    await atProgress(10);
    mailbox.inbox = [_msg(11)];

    await runner.run(_account, mailbox);

    // Each copy would arrive as new mail and match again, forever.
    expect(mailbox.calls, isEmpty);
  });

  test('delete goes to Trash, never the expunging delete', () async {
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.delete)]),
    ]);
    await atProgress(10);
    mailbox.inbox = [_msg(11)];

    await runner.run(_account, mailbox);

    expect(mailbox.calls, ['trash INBOX:11']);
  });

  test('an automatic message is never forwarded', () async {
    // Breaks A→B→A: each forward carries Auto-Submitted, and a rule on the
    // far side will not forward it back.
    await withRules([
      _rule('fwd', 1, const [
        MailRuleAction(
          MailRuleActionKind.forwardTo,
          addresses: ['boss@example.com'],
        ),
        MailRuleAction(MailRuleActionKind.markAsRead),
      ]),
    ]);
    await atProgress(10);
    mailbox
      ..autoSubmitted = {'INBOX:11'}
      ..inbox = [_msg(11)];

    await runner.run(_account, mailbox);

    expect(mailbox.calls, ['read INBOX:11']);
  });

  test('a lost connection stops the run but the claim stands', () async {
    await withRules([
      _rule('r', 1, const [
        MailRuleAction(MailRuleActionKind.moveToFolder, folderId: 'Archive'),
      ]),
    ]);
    await atProgress(10);
    mailbox
      ..inbox = [_msg(11), _msg(12)]
      ..failOn = const NetworkException(message: 'offline');

    await expectLater(
      runner.run(_account, mailbox),
      throwsA(isA<NetworkException>()),
    );
    // At most once: 11 is not offered again, and 12 was never claimed.
    expect((await store.loadProgress(_account.id))!.lastUid, 11);
  });

  test('a capped batch does not skip past what is still waiting', () async {
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.markAsRead)]),
    ]);
    await atProgress(0);
    mailbox
      ..uidNext = 1000
      ..inbox = [
        for (var uid = 1; uid <= LocalMailRuleRunner.batchLimit + 5; uid++)
          _msg(uid),
      ];

    await runner.run(_account, mailbox);

    expect(
      (await store.loadProgress(_account.id))!.lastUid,
      LocalMailRuleRunner.batchLimit,
    );
  });

  test('a short batch moves progress up to UIDNEXT, past claimed mail', () async {
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.markAsRead)]),
    ]);
    await atProgress(10);
    mailbox
      ..uidNext = 21
      ..inbox = [_msg(11)];

    await runner.run(_account, mailbox);

    expect((await store.loadProgress(_account.id))!.lastUid, 20);
  });

  test('the move runs last, and later rules are not consulted', () async {
    await withRules([
      _rule('first', 1, const [
        MailRuleAction(MailRuleActionKind.moveToFolder, folderId: 'Archive'),
        MailRuleAction(MailRuleActionKind.markAsRead),
      ]),
      _rule('later', 2, const [MailRuleAction(MailRuleActionKind.delete)]),
    ]);
    await atProgress(10);
    mailbox.inbox = [_msg(11)];

    final result = await runner.run(_account, mailbox);

    expect(mailbox.calls, ['read INBOX:11', 'move INBOX:11 Archive']);
    expect(result.changedInbox, isTrue);
  });

  test('stop processing ends the list without a move', () async {
    await withRules([
      _rule('first', 1, const [
        MailRuleAction(MailRuleActionKind.star),
        MailRuleAction(MailRuleActionKind.stopProcessingRules),
      ]),
      _rule('later', 2, const [MailRuleAction(MailRuleActionKind.markAsRead)]),
    ]);
    await atProgress(10);
    mailbox.inbox = [_msg(11)];

    await runner.run(_account, mailbox);

    expect(mailbox.calls, [r'flag INBOX:11 \Flagged']);
  });

  test('never forwards to the account itself', () async {
    await withRules([
      _rule('fwd', 1, const [
        MailRuleAction(
          MailRuleActionKind.forwardTo,
          addresses: ['ME@example.com', 'boss@example.com'],
        ),
      ]),
    ]);
    await atProgress(10);
    mailbox.inbox = [_msg(11)];

    await runner.run(_account, mailbox);

    expect(mailbox.calls, ['forward INBOX:11 boss@example.com']);
  });

  test('a message no rule matches is left alone', () async {
    await withRules([
      _rule('r', 1, const [
        MailRuleAction(MailRuleActionKind.delete),
      ], subject: 'invoice'),
    ]);
    await atProgress(10);
    mailbox.inbox = [_msg(11)];

    final result = await runner.run(_account, mailbox);

    expect(mailbox.calls, isEmpty);
    expect(result.processed, 1);
    expect(result.changedInbox, isFalse);
  });

  test('rules are paused while a migration fills the Inbox', () async {
    // Copied mail arrives as new UIDs; the rules would act on mail the old
    // server's rules already handled.
    await withRules([
      _rule('r', 1, const [MailRuleAction(MailRuleActionKind.delete)]),
    ]);
    await atProgress(10);
    mailbox.inbox = [_msg(11)];
    final paused = LocalMailRuleRunner(
      store: store,
      isMigrationTarget: (id) async => id == _account.id,
    );

    await paused.run(_account, mailbox);

    expect(mailbox.calls, isEmpty);
    // Forgotten, so the rules restart from "now", past every copied message.
    expect(await store.loadProgress(_account.id), isNull);
  });
}
