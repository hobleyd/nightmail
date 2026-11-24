import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/email_attachment.dart';
import 'package:nightmail/domain/usecases/ai/agent/email_safety_signals.dart';
import 'package:nightmail/domain/usecases/check_sender_anomaly.dart';

void main() {
  Email email({
    String from = 'billing@paypal.com',
    String? name = 'PayPal',
    String body = '',
    EmailBodyType bodyType = EmailBodyType.html,
    List<EmailAttachment> attachments = const [],
  }) =>
      Email(
        id: 'm1',
        subject: 'Your account',
        from: EmailAddress(address: from, name: name),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: '',
        body: body,
        bodyType: bodyType,
        isRead: false,
        receivedDateTime: DateTime.utc(2026, 11, 24),
        importance: EmailImportance.normal,
        attachments: attachments,
      );

  Uint8List raw(String headers) =>
      Uint8List.fromList(latin1.encode('$headers\r\n\r\nBODY dkim=pass\r\n'));

  group('parseHeaderBlock', () {
    test('unfolds continuation lines and stops at the blank line', () {
      final headers = parseHeaderBlock(raw(
        'Authentication-Results: mx.google.com;\r\n'
        '       spf=fail smtp.mailfrom=evil.example\r\n'
        'Subject: hi',
      ));
      expect(headers, [
        ('authentication-results', 'mx.google.com; spf=fail smtp.mailfrom=evil.example'),
        ('subject', 'hi'),
      ]);
    });

    test('bare LF line endings work too', () {
      final bytes = Uint8List.fromList(latin1.encode('A: 1\nB: 2\n\nC: 3\n'));
      expect(parseHeaderBlock(bytes), [('a', '1'), ('b', '2')]);
    });
  });

  group('emailSafetySignals', () {
    test('reads SPF/DKIM/DMARC from the topmost Authentication-Results', () {
      final signals = emailSafetySignals(
        email: email(),
        rawSource: raw(
          'Authentication-Results: mx.google.com; dkim=fail; spf=softfail; '
          'dmarc=fail (p=REJECT)\r\n'
          'Authentication-Results: relay.example; dkim=pass; spf=pass',
        ),
      );
      expect(signals['authentication'],
          {'spf': 'softfail', 'dkim': 'fail', 'dmarc': 'fail'});
    });

    test('flags a Reply-To and Return-Path on another domain, not a subdomain',
        () {
      final signals = emailSafetySignals(
        email: email(),
        rawSource: raw(
          'Reply-To: "PayPal" <support@paypa1-help.ru>\r\n'
          'Return-Path: <bounce@mail.paypal.com>',
        ),
      );
      expect(signals['replyTo'], {
        'address': 'support@paypa1-help.ru',
        'differentDomainFromSender': true,
      });
      expect(
          (signals['returnPath'] as Map)['differentDomainFromSender'], isFalse);
    });

    test('no raw source says the header evidence is unknown', () {
      final signals = emailSafetySignals(email: email());
      expect(signals['authentication'], contains('unavailable'));
      expect(signals.containsKey('replyTo'), isFalse);
    });

    test('a display name carrying another address is reported', () {
      final signals = emailSafetySignals(
        email: email(from: 'x@evil.example', name: 'security@paypal.com'),
      );
      expect(signals['displayNameShowsOtherAddress'], 'security@paypal.com');
    });

    test('links whose text names another domain are reported as hosts only',
        () {
      final signals = emailSafetySignals(
        email: email(
          body: '<p><a href="https://evil.example/login?token=SECRET">'
              '<b>www.paypal.com</b></a> '
              '<a href="https://www.paypal.com/help">Help centre</a> '
              '<a href="http://192.168.4.4/x">here</a> '
              '<a href="https://xn--pypal-4ve.com/">paypal.com</a></p>',
        ),
      );
      final links = signals['links'] as Map<String, dynamic>;
      expect(links['textShowsDifferentDomain'], [
        {'shows': 'www.paypal.com', 'goesTo': 'evil.example'},
        {'shows': 'paypal.com', 'goesTo': 'xn--pypal-4ve.com'},
      ]);
      expect(links['rawIpHosts'], ['192.168.4.4']);
      expect(links['punycodeHosts'], ['xn--pypal-4ve.com']);
      expect(links['plainHttpHosts'], ['192.168.4.4']);
      expect(links['domainsOtherThanSender'],
          isNot(contains('paypal.com')));
      expect(jsonEncode(signals), isNot(contains('SECRET')));
    });

    test('plain-text bodies still list link hosts', () {
      final signals = emailSafetySignals(
        email: email(
          bodyType: EmailBodyType.text,
          body: 'Verify at https://evil.example/a now',
        ),
      );
      expect((signals['links'] as Map)['hosts'], ['evil.example']);
    });

    test('risky and double-extension attachments are flagged', () {
      final signals = emailSafetySignals(
        email: email(attachments: const [
          EmailAttachment(
              id: 'a', name: 'invoice.pdf.exe', contentType: 'x', size: 1),
          EmailAttachment(
              id: 'b', name: 'report.pdf', contentType: 'x', size: 1),
        ]),
      );
      final attachments = signals['attachments'] as List;
      expect(attachments[0]['riskyType'], isTrue);
      expect(attachments[0]['doubleExtension'], isTrue);
      expect((attachments[1] as Map).containsKey('riskyType'), isFalse);
    });

    test('a lookalike of a known sender lists the real addresses', () {
      final signals = emailSafetySignals(
        email: email(),
        senderAnomaly: const SenderAnomalyResult(
          score: 0.95,
          matches: [(address: 'service@paypal.com.au', name: 'PayPal')],
        ),
      );
      expect((signals['lookalikeOfKnownSender'] as Map)['knownAddresses'],
          ['PayPal <service@paypal.com.au>']);
    });
  });
}
