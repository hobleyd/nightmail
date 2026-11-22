import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/cloud_file_access_matcher.dart';

void main() {
  CloudFileAccessMatcher matcher() =>
      CloudFileAccessMatcher(organizationDomains: {'contoso.com'});

  const recipients = ['Alice@Contoso.com', 'bob@fabrikam.com'];

  group('Graph permissions', () {
    test('an anonymous link covers everyone and is offered as the link', () {
      final m = matcher()
        ..addGraphPermission({
          'link': {'scope': 'anonymous', 'webUrl': 'https://x/s/abc'},
        });
      expect(m.uncovered(recipients), isEmpty);
      expect(m.anyoneLinkUrl, 'https://x/s/abc');
    });

    test('an organization link covers only internal recipients', () {
      final m = matcher()
        ..addGraphPermission({
          'link': {'scope': 'organization'},
        });
      expect(m.uncovered(recipients), ['bob@fabrikam.com']);
    });

    test('a direct grant covers that address, case-insensitively', () {
      final m = matcher()
        ..addGraphPermission({
          'grantedToV2': {
            'user': {'email': 'BOB@fabrikam.com'},
          },
        });
      expect(m.uncovered(recipients), ['Alice@Contoso.com']);
    });

    test('a users link lists its identities', () {
      final m = matcher()
        ..addGraphPermission({
          'link': {'scope': 'users'},
          'grantedToIdentitiesV2': [
            {
              'user': {'email': 'alice@contoso.com'},
            },
            {
              'siteUser': {'loginName': 'i:0#.f|membership|bob@fabrikam.com'},
            },
          ],
        });
      expect(m.uncovered(recipients), isEmpty);
    });

    test('a pending invitation covers the invited address', () {
      final m = matcher()
        ..addGraphPermission({
          'invitation': {'email': 'bob@fabrikam.com'},
        });
      expect(m.uncovered(recipients), ['Alice@Contoso.com']);
    });

    test('a site group is taken to hold colleagues, never outsiders', () {
      final m = matcher()
        ..addGraphPermission({
          'grantedToV2': {
            'siteGroup': {'displayName': 'Finance Members'},
          },
        });
      expect(m.uncovered(recipients), ['bob@fabrikam.com']);
    });

    test('with no permissions at all, nobody is covered', () {
      expect(matcher().uncovered(recipients), recipients);
    });
  });

  group('Drive permissions', () {
    test('anyone-with-the-link covers everyone, through the view link', () {
      final m = matcher()
        ..addDrivePermission({'type': 'anyone', 'role': 'reader'},
            webViewLink: 'https://docs.google.com/d/1/view');
      expect(m.uncovered(recipients), isEmpty);
      expect(m.anyoneLinkUrl, 'https://docs.google.com/d/1/view');
    });

    test('a domain permission covers that domain only', () {
      final m = matcher()
        ..addDrivePermission({'type': 'domain', 'domain': 'fabrikam.com'});
      expect(m.uncovered(recipients), ['Alice@Contoso.com']);
    });

    test('a user permission covers that user', () {
      final m = matcher()
        ..addDrivePermission(
            {'type': 'user', 'emailAddress': 'alice@contoso.com'});
      expect(m.uncovered(recipients), ['bob@fabrikam.com']);
    });
  });
}
