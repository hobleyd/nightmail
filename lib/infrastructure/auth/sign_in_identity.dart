import '../../core/error/exceptions.dart';
import 'auth_token.dart';
import 'signed_in_mailbox_lookup.dart';

/// A check a freshly obtained token must pass before an auth service stores
/// it. Throwing an [AuthException] refuses the token: nothing is written, and
/// whatever token was stored before stays.
typedef SignInVerifier = Future<void> Function(AuthToken token);

/// The reason to refuse a token for the account at [accountEmail], given the
/// addresses the provider says the token's mailbox answers for — or null to
/// accept it.
///
/// Any one address matching is enough, so an account recorded under an alias
/// still passes. Compared case-insensitively and ignoring surrounding
/// whitespace: addresses are typed into Settings by hand. An empty
/// [signedInAddresses] is "could not tell" and refuses nothing; so does an
/// account with no address to compare against.
String? signInIdentityRefusal({
  required String accountEmail,
  required List<String> signedInAddresses,
}) {
  final expected = _normalise(accountEmail);
  if (expected.isEmpty || signedInAddresses.isEmpty) return null;
  if (signedInAddresses.any((a) => _normalise(a) == expected)) return null;
  return 'You signed in as ${signedInAddresses.first}, but this account is '
      '$accountEmail. Sign in again and choose $accountEmail.';
}

/// The [SignInVerifier] for an account that already exists: refuses a token
/// that belongs to another mailbox and otherwise reports, through
/// [onAddressesLearned], every address the provider says the mailbox answers
/// for, primary first — the address itself for an account recorded without
/// one, and the aliases for every account, so they stay current with each
/// sign-in (see `Account.withMailboxAddresses`).
///
/// An empty answer from [lookup] accepts the token, as every sign-in used to
/// be accepted. A failed lookup right after a successful code exchange is a
/// network hiccup, not evidence about who signed in, and refusing on it would
/// lock the user out of an account whose sign-in just worked.
SignInVerifier mailboxGuard({
  required String accountEmail,
  required SignedInMailboxLookup lookup,
  required void Function(List<String> addresses) onAddressesLearned,
}) {
  return (token) async {
    final addresses = await lookup.addressesFor(token);
    if (addresses.isEmpty) return;
    final refusal = signInIdentityRefusal(
      accountEmail: accountEmail,
      signedInAddresses: addresses,
    );
    if (refusal != null) throw AuthException(message: refusal);
    onAddressesLearned(addresses);
  };
}

String _normalise(String address) => address.trim().toLowerCase();
