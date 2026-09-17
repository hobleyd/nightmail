import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/consumer_email_domain.dart';
import 'package:nightmail/domain/entities/out_of_office_settings.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/presentation/pages/settings/out_of_office_page.dart';

const _microsoft = MicrosoftAccount(
  id: 'm',
  displayName: 'Work',
  emailAddress: 'me@contoso.com',
  tenantId: 'common',
);
const _workspace = GmailAccount(
  id: 'w',
  displayName: 'Workspace',
  emailAddress: 'me@contoso.com',
);
const _consumer = GmailAccount(
  id: 'g',
  displayName: 'Personal',
  emailAddress: 'me@gmail.com',
);

void main() {
  group('who the audience options are offered to', () {
    test('a personal Gmail account is not offered "organisation only"', () {
      // Gmail's `restrictToDomain` means nothing on @gmail.com — offering it
      // there would be a control that silently does nothing.
      expect(
        outOfOfficeAudienceOptions(_consumer, OutOfOfficeAudience.everyone),
        isNot(contains(OutOfOfficeAudience.organisationOnly)),
      );
    });

    test('unless the mailbox is already set that way', () {
      // A dropdown whose current value is missing from its own items throws,
      // so the option has to be listed even where it is not offered.
      expect(
        outOfOfficeAudienceOptions(
            _consumer, OutOfOfficeAudience.organisationOnly),
        contains(OutOfOfficeAudience.organisationOnly),
      );
    });

    test('every option is offered to Workspace and Microsoft accounts', () {
      for (final account in [_workspace, _microsoft, null]) {
        expect(
          outOfOfficeAudienceOptions(account, OutOfOfficeAudience.everyone),
          OutOfOfficeAudience.values,
          reason: '${account?.emailAddress}',
        );
      }
    });
  });

  group('how they are worded', () {
    test('the two providers differ on who a contacts-only reply reaches', () {
      // Microsoft always answers everyone inside the organisation and the
      // choice governs only outsiders; Gmail's restrictToContacts is the whole
      // rule, so a colleague who is not a contact gets nothing. One wording
      // for both would be wrong for one of them.
      expect(
        outOfOfficeAudienceLabel(OutOfOfficeAudience.contacts, _microsoft),
        'My organisation and my contacts',
      );
      expect(
        outOfOfficeAudienceLabel(OutOfOfficeAudience.contacts, _workspace),
        'People in my contacts',
      );
    });

    test('every option has a label on every provider', () {
      for (final account in [_microsoft, _workspace, _consumer, null]) {
        for (final audience in OutOfOfficeAudience.values) {
          expect(outOfOfficeAudienceLabel(audience, account), isNotEmpty);
        }
      }
    });
  });

  group('the shared consumer-domain rule', () {
    test('recognises Google\'s consumer domains', () {
      expect(isConsumerGoogleAddress('me@gmail.com'), isTrue);
      expect(isConsumerGoogleAddress('Me@GoogleMail.COM'), isTrue);
    });

    test('treats anything unrecognised as a Workspace domain', () {
      // The recoverable direction: the API refuses, or the option has no
      // effect. The other way removes a working control.
      expect(isConsumerGoogleAddress('me@contoso.com'), isFalse);
    });

    test('an address it cannot read is treated as consumer', () {
      // Used by GmailAuthService.scopesForAccount, where "we do not know who
      // is signing in" must not send an admin.directory scope — Google
      // refuses the whole authorization request for one.
      expect(isConsumerGoogleAddress(null), isTrue);
      expect(isConsumerGoogleAddress('not-an-address'), isTrue);
    });
  });
}
