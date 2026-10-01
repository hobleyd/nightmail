import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/infrastructure/auth/sign_in_identity.dart';
import 'package:nightmail/infrastructure/auth/signed_in_mailbox_lookup.dart';

class _FakeLookup implements SignedInMailboxLookup {
  _FakeLookup(this.addresses);

  final List<String> addresses;
  AuthToken? askedWith;

  @override
  Future<List<String>> addressesFor(AuthToken token) async {
    askedWith = token;
    return addresses;
  }
}

/// `login_hint` only suggests an account: after a forced password reset the
/// browser's session for the account is gone, and the one still signed in
/// there is routinely another of the user's accounts. These pin the rule that
/// decides whether the token that came back may be kept for the account the
/// sign-in was started for.
void main() {
  final token = AuthToken(
    accessToken: 'fresh',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );

  group('signInIdentityRefusal', () {
    test("accepts the account's own address", () {
      expect(
        signInIdentityRefusal(
          accountEmail: 'me@htw.com.au',
          signedInAddresses: const ['me@htw.com.au'],
        ),
        isNull,
      );
    });

    test('ignores case and surrounding whitespace — Settings is typed by hand',
        () {
      expect(
        signInIdentityRefusal(
          accountEmail: ' Me@HTW.com.au ',
          signedInAddresses: const ['me@htw.com.au'],
        ),
        isNull,
      );
    });

    test('accepts an alias the provider lists for the mailbox', () {
      expect(
        signInIdentityRefusal(
          accountEmail: 'alias@htw.com.au',
          signedInAddresses: const ['me@htw.com.au', 'alias@htw.com.au'],
        ),
        isNull,
      );
    });

    test('refuses another mailbox, naming both addresses', () {
      final refusal = signInIdentityRefusal(
        accountEmail: 'me@htw.com.au',
        signedInAddresses: const ['me@sharpblue.com.au'],
      );
      expect(refusal, isNotNull);
      expect(refusal, contains('me@sharpblue.com.au'));
      expect(refusal, contains('me@htw.com.au'));
    });

    test('an empty answer from the provider is "could not tell", not a refusal',
        () {
      expect(
        signInIdentityRefusal(
          accountEmail: 'me@htw.com.au',
          signedInAddresses: const [],
        ),
        isNull,
      );
    });

    test('an account with no address has nothing to refuse against', () {
      expect(
        signInIdentityRefusal(
          accountEmail: '',
          signedInAddresses: const ['me@sharpblue.com.au'],
        ),
        isNull,
      );
    });
  });

  group('mailboxGuard', () {
    test("passes a token for the account's own mailbox", () async {
      final guard = mailboxGuard(
        accountEmail: 'me@htw.com.au',
        lookup: _FakeLookup(const ['me@htw.com.au']),
        onAddressLearned: (_) => fail('nothing to learn'),
      );
      await guard(token);
    });

    test('refuses a token for another mailbox with an AuthException', () async {
      final guard = mailboxGuard(
        accountEmail: 'me@htw.com.au',
        lookup: _FakeLookup(const ['me@sharpblue.com.au']),
        onAddressLearned: (_) => fail('nothing to learn'),
      );
      await expectLater(
        guard(token),
        throwsA(isA<AuthException>().having(
          (e) => e.message,
          'message',
          contains('me@sharpblue.com.au'),
        )),
      );
    });

    test('adopts the primary address for an account recorded without one',
        () async {
      String? learned;
      final guard = mailboxGuard(
        accountEmail: '',
        lookup: _FakeLookup(const ['me@htw.com.au', 'alias@htw.com.au']),
        onAddressLearned: (address) => learned = address,
      );
      await guard(token);
      expect(learned, 'me@htw.com.au');
    });

    test('accepts, and learns nothing, when the provider could not say',
        () async {
      final guard = mailboxGuard(
        accountEmail: '',
        lookup: _FakeLookup(const []),
        onAddressLearned: (_) => fail('an unknown answer teaches nothing'),
      );
      await guard(token);
    });

    test('asks the provider with the token under test, not a stored one',
        () async {
      final lookup = _FakeLookup(const ['me@htw.com.au']);
      await mailboxGuard(
        accountEmail: 'me@htw.com.au',
        lookup: lookup,
        onAddressLearned: (_) {},
      )(token);
      expect(lookup.askedWith, same(token));
    });
  });
}
