/// Decides which recipients a cloud file's permissions do *not* cover.
///
/// Built from whatever the provider lists — Graph `/permissions` (Microsoft
/// and a NightMail Server alike) or Drive `permissions.list` — and then asked
/// about each recipient. Neither provider has a "can this address open it"
/// call, so this is a reading of the permission list, and it leans the way
/// that costs least when it is wrong:
///
/// * A permission granted to a **group** (a SharePoint site group, an Entra or
///   Google group) cannot be expanded to addresses. Recipients inside the
///   sender's own organization are taken to be in it — the everyday case of a
///   file in a team site linked to a colleague, where asking every time would
///   train the sender to click straight through. Outside recipients still are
///   not.
/// * Anything else unrecognised covers nobody, so the sender is asked: a
///   needless "share it with them?" costs a click, a link nobody can open
///   costs a reply asking for access.
class CloudFileAccessMatcher {
  CloudFileAccessMatcher({required Set<String> organizationDomains})
      : _organizationDomains =
            organizationDomains.map((d) => d.toLowerCase()).toSet();

  final Set<String> _organizationDomains;

  final Set<String> _emails = {};
  final Set<String> _domains = {};
  bool _anyone = false;
  bool _organization = false;
  bool _unresolvedGroup = false;

  /// An "anyone with the link" sharing URL, when the item has one.
  String? anyoneLinkUrl;

  void addAnyone({String? linkUrl}) {
    _anyone = true;
    anyoneLinkUrl ??= linkUrl;
  }

  void addOrganization() => _organization = true;
  void addDomain(String domain) => _domains.add(domain.toLowerCase());
  void addEmail(String email) => _emails.add(email.trim().toLowerCase());
  void addUnresolvedGroup() => _unresolvedGroup = true;

  /// [recipients] no permission covers, in the order given.
  List<String> uncovered(List<String> recipients) {
    if (_anyone) return const [];
    return [
      for (final recipient in recipients)
        if (!_covers(recipient)) recipient,
    ];
  }

  bool _covers(String recipient) {
    final address = recipient.trim().toLowerCase();
    if (_emails.contains(address)) return true;
    final at = address.lastIndexOf('@');
    if (at < 0) return false;
    final domain = address.substring(at + 1);
    if (_domains.contains(domain)) return true;
    final internal = _organizationDomains.contains(domain);
    return internal && (_organization || _unresolvedGroup);
  }

  /// Reads one Graph `permission` resource.
  ///
  /// The shapes that matter: a `link` (scope `anonymous`, `organization` or
  /// `users` with `grantedToIdentitiesV2`), a direct grant (`grantedToV2.user`
  /// or `.siteUser`, or the v1 `grantedTo`), an invitation still pending
  /// (`invitation.email`), and a group (`grantedToV2.group`/`.siteGroup`).
  void addGraphPermission(Map<String, dynamic> permission) {
    final link = permission['link'];
    if (link is Map<String, dynamic>) {
      switch (link['scope']) {
        case 'anonymous':
          addAnyone(linkUrl: link['webUrl'] as String?);
          return;
        case 'organization':
          addOrganization();
          return;
      }
    }

    final invitation = permission['invitation'];
    if (invitation is Map<String, dynamic>) {
      final email = invitation['email'];
      if (email is String && email.isNotEmpty) addEmail(email);
    }

    final identities = [
      permission['grantedToV2'],
      permission['grantedTo'],
      ...?(permission['grantedToIdentitiesV2'] as List?),
      ...?(permission['grantedToIdentities'] as List?),
    ];
    for (final identity in identities) {
      if (identity is! Map<String, dynamic>) continue;
      for (final key in const ['user', 'siteUser']) {
        final user = identity[key];
        if (user is! Map<String, dynamic>) continue;
        final email = user['email'];
        if (email is String && email.contains('@')) addEmail(email);
        // A SharePoint siteUser's loginName is a claims string ending in the
        // address: `i:0#.f|membership|alice@contoso.com`.
        final login = user['loginName'];
        if (login is String && login.contains('@')) {
          addEmail(login.split('|').last);
        }
      }
      if (identity['group'] is Map || identity['siteGroup'] is Map) {
        addUnresolvedGroup();
      }
    }
  }

  /// Reads one Drive `permission` resource: `type` is `anyone`, `domain`,
  /// `user` or `group`.
  void addDrivePermission(Map<String, dynamic> permission,
      {String? webViewLink}) {
    switch (permission['type']) {
      case 'anyone':
        addAnyone(linkUrl: webViewLink);
      case 'domain':
        final domain = permission['domain'];
        if (domain is String && domain.isNotEmpty) addDomain(domain);
      case 'user':
        final email = permission['emailAddress'];
        if (email is String && email.isNotEmpty) addEmail(email);
      case 'group':
        addUnresolvedGroup();
        final email = permission['emailAddress'];
        // A recipient who *is* the group address is covered by it.
        if (email is String && email.isNotEmpty) addEmail(email);
    }
  }
}
