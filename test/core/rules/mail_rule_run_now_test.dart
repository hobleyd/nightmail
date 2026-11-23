import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/rules/mail_rule_matcher.dart';
import 'package:nightmail/core/rules/mail_rule_run_now.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/mail_rule.dart';

Email _email(
  String id, {
  String from = 'news@example.com',
  bool isRead = false,
  String folderId = 'inbox',
  List<String> folderIds = const [],
}) => Email(
  id: id,
  subject: 'Weekly digest',
  from: EmailAddress(address: from),
  toRecipients: const [EmailAddress(address: 'me@example.com')],
  ccRecipients: const [],
  bodyPreview: '',
  body: '',
  bodyType: EmailBodyType.text,
  isRead: isRead,
  receivedDateTime: DateTime(2026, 11, 20),
  importance: EmailImportance.normal,
  parentFolderId: folderId,
  folderIds: folderIds,
);

const _fromNews = MailRuleCondition(
  MailRuleConditionKind.fromAddresses,
  values: ['news@example.com'],
);

MailRule _rule(
  List<MailRuleAction> actions, {
  List<MailRuleCondition> conditions = const [_fromNews],
  List<MailRuleCondition> exceptions = const [],
}) => MailRule(conditions: conditions, exceptions: exceptions, actions: actions);

const _markRead = MailRuleAction(MailRuleActionKind.markAsRead);
const _moveToNews = MailRuleAction(
  MailRuleActionKind.moveToFolder,
  folderId: 'news',
);

void main() {
  final matcher = MailRuleMatcher(myAddresses: ['me@example.com']);

  group('unavailableReason', () {
    test('allows move, delete and mark read on what a list row carries', () {
      expect(MailRuleRunNow.unavailableReason(_rule([_moveToNews, _markRead])),
          isNull);
      expect(
        MailRuleRunNow.unavailableReason(
          _rule([const MailRuleAction(MailRuleActionKind.delete)]),
        ),
        isNull,
      );
    });

    test('refuses forwarding: old mail would go to other people', () {
      expect(
        MailRuleRunNow.unavailableReason(
          _rule([
            const MailRuleAction(
              MailRuleActionKind.forwardTo,
              addresses: ['x@example.com'],
            ),
          ]),
        ),
        contains('forwards'),
      );
    });

    test('refuses an exception it cannot test — it would widen the rule', () {
      // An untestable exception answers false, so it would never cancel the
      // rule and the run would act on more mail than the rule says.
      expect(
        MailRuleRunNow.unavailableReason(
          _rule(
            [_moveToNews],
            exceptions: const [
              MailRuleCondition(
                MailRuleConditionKind.importance,
                importance: MailRuleImportance.high,
              ),
            ],
          ),
        ),
        isNotNull,
      );
    });

    test('refuses body tests, which a list row cannot answer', () {
      expect(
        MailRuleRunNow.unavailableReason(
          _rule(
            [_markRead],
            conditions: const [
              MailRuleCondition(
                MailRuleConditionKind.bodyOrSubjectContains,
                values: ['invoice'],
              ),
            ],
          ),
        ),
        isNotNull,
      );
    });

    test('refuses an attachment test on Gmail, whose rows never say', () {
      final rule = _rule(
        [_moveToNews],
        conditions: const [
          MailRuleCondition(MailRuleConditionKind.hasAttachments),
        ],
      );
      expect(MailRuleRunNow.unavailableReason(rule), isNull);
      expect(MailRuleRunNow.unavailableReason(rule, google: true), isNotNull);
    });

    test('refuses actions the list cannot do', () {
      expect(
        MailRuleRunNow.unavailableReason(
          _rule([const MailRuleAction(MailRuleActionKind.archive)]),
        ),
        isNotNull,
      );
    });
  });

  group('plan', () {
    test('matches only messages that are themselves in the folder', () {
      final plan = MailRuleRunNow.plan(
        _rule([_moveToNews]),
        [
          _email('a'),
          _email('b', from: 'boss@example.com'),
          // A thread's copy from Sent, listed beside its reply.
          _email('c', folderId: 'sent'),
          _email('a'),
        ],
        folderId: 'inbox',
        matcher: matcher,
      );
      expect(plan.matchedIds, ['a']);
      expect(plan.moveToFolderId, 'news');
      expect(plan.delete, isFalse);
    });

    test('marks read only what is unread', () {
      final plan = MailRuleRunNow.plan(
        _rule([_markRead]),
        [_email('a'), _email('b', isRead: true)],
        folderId: 'inbox',
        matcher: matcher,
      );
      expect(plan.matchedIds, ['a', 'b']);
      expect(plan.markReadIds, ['a']);
      expect(plan.isEmpty, isFalse);
    });

    test('a move into the folder being run moves nothing', () {
      final plan = MailRuleRunNow.plan(
        _rule([_moveToNews]),
        [_email('a', folderId: 'news')],
        folderId: 'news',
        matcher: matcher,
      );
      expect(plan.moveToFolderId, isNull);
      expect(plan.isEmpty, isTrue);
    });

    test('the first of move and delete wins', () {
      final plan = MailRuleRunNow.plan(
        _rule([const MailRuleAction(MailRuleActionKind.delete), _moveToNews]),
        [_email('a')],
        folderId: 'inbox',
        matcher: matcher,
      );
      expect(plan.delete, isTrue);
      expect(plan.moveToFolderId, isNull);
    });

    test('leaves a Gmail SENT copy alone even where it carries the label', () {
      final plan = MailRuleRunNow.plan(
        _rule([_moveToNews]),
        [
          _email('a', folderIds: ['INBOX']),
          _email('b', folderIds: ['INBOX', 'SENT']),
        ],
        folderId: 'INBOX',
        matcher: matcher,
      );
      expect(plan.matchedIds, ['a']);
    });

    test('plans nothing for a rule it cannot run', () {
      final plan = MailRuleRunNow.plan(
        _rule([
          const MailRuleAction(
            MailRuleActionKind.forwardTo,
            addresses: ['x@example.com'],
          ),
        ]),
        [_email('a')],
        folderId: 'inbox',
        matcher: matcher,
      );
      expect(plan.isEmpty, isTrue);
    });
  });
}
