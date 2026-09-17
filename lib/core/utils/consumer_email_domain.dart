/// Whether [emailAddress] is a *consumer* Google account rather than one on a
/// Workspace (or Cloud Identity) domain.
///
/// One rule, read in two very different places, because two copies of this
/// list is how the same account comes to be two different things in one app:
///
/// * `GmailAuthService.scopesForAccount` — a personal account must not be sent
///   an `admin.directory.*` scope, which Google refuses with `invalid_scope`
///   for the *whole* authorization request.
/// * The Out of Office screen — "people in my organisation only" is Gmail's
///   `restrictToDomain`, which means nothing on `@gmail.com`, so the option is
///   not offered there.
///
/// Anything unrecognised is treated as a Workspace domain: that is the
/// direction where being wrong is recoverable (the API refuses, or the option
/// simply has no effect), where the other way removes a working control.
bool isConsumerGoogleAddress(String? emailAddress) {
  final email = emailAddress?.trim().toLowerCase();
  if (email == null || !email.contains('@')) return true;
  final domain = email.split('@').last;
  if (domain.isEmpty) return true;
  return _consumerDomains.contains(domain);
}

const _consumerDomains = {'gmail.com', 'googlemail.com'};
