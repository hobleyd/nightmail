import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/rules/mail_rule_matcher.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/mail_rule.dart';

Email _email({
  String subject = 'Quarterly numbers',
  String from = 'alice@example.com',
  String fromName = 'Alice Smith',
  List<String> to = const ['me@example.com'],
  List<String> cc = const [],
  String body = '',
  EmailBodyType bodyType = EmailBodyType.text,
  bool hasAttachments = false,
}) => Email(
  id: 'INBOX:1',
  subject: subject,
  from: EmailAddress(address: from, name: fromName),
  toRecipients: [for (final a in to) EmailAddress(address: a)],
  ccRecipients: [for (final a in cc) EmailAddress(address: a)],
  bodyPreview: '',
  body: body,
  bodyType: bodyType,
  isRead: false,
  receivedDateTime: DateTime(2026, 11, 20),
  importance: EmailImportance.normal,
  hasAttachments: hasAttachments,
);

MailRule _rule(
  List<MailRuleCondition> conditions, {
  List<MailRuleCondition> exceptions = const [],
}) => MailRule(
  conditions: conditions,
  exceptions: exceptions,
  actions: const [MailRuleAction(MailRuleActionKind.markAsRead)],
);

MailRuleCondition _text(MailRuleConditionKind kind, List<String> values) =>
    MailRuleCondition(kind, values: values);

void main() {
  final matcher = MailRuleMatcher(
    myAddresses: ['Me@Example.com', 'alias@example.com'],
  );

  test('every condition must hold; values within one are alternatives', () {
    final rule = _rule([
      _text(MailRuleConditionKind.senderContains, ['bob', 'alice']),
      _text(MailRuleConditionKind.subjectContains, ['QUARTERLY']),
    ]);

    expect(matcher.matches(rule, _email()), isTrue);
    expect(matcher.matches(rule, _email(subject: 'Lunch')), isFalse);
  });

  test('sender contains matches the display name as well as the address', () {
    final rule = _rule([
      _text(MailRuleConditionKind.senderContains, ['smith']),
    ]);

    expect(matcher.matches(rule, _email()), isTrue);
  });

  test('from is a whole address, case-insensitive', () {
    final rule = _rule([
      _text(MailRuleConditionKind.fromAddresses, ['ALICE@example.com']),
    ]);

    expect(matcher.matches(rule, _email()), isTrue);
    expect(matcher.matches(rule, _email(from: 'malice@example.com')), isFalse);
  });

  test('any exception that holds cancels the rule', () {
    final rule = _rule(
      [const MailRuleCondition(MailRuleConditionKind.sentToMe)],
      exceptions: [
        _text(MailRuleConditionKind.subjectContains, ['numbers']),
      ],
    );

    expect(matcher.matches(rule, _email()), isFalse);
    expect(matcher.matches(rule, _email(subject: 'Hello')), isTrue);
  });

  test('body tests read the rendered text, not the markup', () {
    final rule = _rule([
      _text(MailRuleConditionKind.bodyContains, ['price']),
    ]);
    final html = _email(
      body: '<table class="price-table"><tr><td>Hello</td></tr></table>',
      bodyType: EmailBodyType.html,
    );

    expect(matcher.matches(rule, html), isFalse);
    expect(
      matcher.matches(
        rule,
        _email(body: '<p>The Price is right</p>', bodyType: EmailBodyType.html),
      ),
      isTrue,
    );
  });

  group('sent to me', () {
    MailRule only(MailRuleConditionKind kind) =>
        _rule([MailRuleCondition(kind)]);

    test('counts aliases as me', () {
      expect(
        matcher.matches(
          only(MailRuleConditionKind.sentToMe),
          _email(to: ['alias@example.com']),
        ),
        isTrue,
      );
    });

    test('only to me means alone on To and nobody on Cc', () {
      final rule = only(MailRuleConditionKind.sentOnlyToMe);
      expect(matcher.matches(rule, _email()), isTrue);
      expect(
        matcher.matches(rule, _email(to: ['me@example.com', 'x@example.com'])),
        isFalse,
      );
      expect(
        matcher.matches(rule, _email(cc: ['x@example.com'])),
        isFalse,
      );
    });

    test('Cc and not-on-To', () {
      final mail = _email(to: ['x@example.com'], cc: ['me@example.com']);
      expect(matcher.matches(only(MailRuleConditionKind.sentCcMe), mail), isTrue);
      expect(
        matcher.matches(only(MailRuleConditionKind.notSentToMe), mail),
        isTrue,
      );
      expect(
        matcher.matches(only(MailRuleConditionKind.sentToOrCcMe), mail),
        isTrue,
      );
    });
  });

  test('a disabled rule, or one with no conditions, never matches', () {
    expect(
      matcher.matches(
        _rule([const MailRuleCondition(MailRuleConditionKind.sentToMe)])
            .copyWith(enabled: false),
        _email(),
      ),
      isFalse,
    );
    expect(matcher.matches(_rule(const []), _email()), isFalse);
  });

  test('a condition IMAP cannot test does not fire on everything', () {
    final rule = _rule([
      const MailRuleCondition(
        MailRuleConditionKind.importance,
        importance: MailRuleImportance.high,
      ),
    ]);

    expect(matcher.matches(rule, _email()), isFalse);
  });
}
