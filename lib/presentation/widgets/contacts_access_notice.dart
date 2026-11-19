import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/settings/app_settings.dart';
import '../../domain/repositories/system_contacts_repository.dart';
import '../../injection_container.dart';

/// What the startup check should do with the Contacts permission it found.
enum ContactsAccessAction {
  /// First time seen granted: record it, so a later loss can be recognised.
  remember,

  /// Granted before, refused now: the reader lost something they had.
  warn,

  none,
}

/// Warns only on a *loss*. Someone who declined Contacts access on purpose —
/// or never had a dialog to answer — is never nagged about it; someone whose
/// typeahead quietly stopped offering Contacts names after an update is told
/// why and where to fix it. Seen 2026-11-19: every launch after the 1.47.3
/// install answered `denied` (refused, no dialog) where the launch before it
/// answered `granted`, and relaunching did not bring it back.
ContactsAccessAction contactsAccessAction({
  required bool grantedBefore,
  required ContactsPermission permission,
}) =>
    switch (permission) {
      ContactsPermission.granted =>
        grantedBefore ? ContactsAccessAction.none : ContactsAccessAction.remember,
      ContactsPermission.denied ||
      ContactsPermission.permanentlyDenied =>
        grantedBefore ? ContactsAccessAction.warn : ContactsAccessAction.none,
      ContactsPermission.unsupported => ContactsAccessAction.none,
    };

const _contactsPrivacyPane =
    'x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts';

/// Checks the Contacts permission once the main window is up and, if it has
/// been lost, shows a banner that says so. macOS only — the only platform with
/// an OS address book source. Main window only: it is the one that syncs the
/// address book, and the banner needs its [ScaffoldMessenger].
Future<void> checkContactsAccess(BuildContext context) async {
  if (kIsWeb || !Platform.isMacOS) return;
  final settings = sl<AppSettings>();
  final permission = await sl<SystemContactsRepository>().permission();
  final grantedBefore = await settings.loadContactsAccessGranted();
  switch (contactsAccessAction(
      grantedBefore: grantedBefore, permission: permission)) {
    case ContactsAccessAction.remember:
      await settings.saveContactsAccessGranted(true);
    case ContactsAccessAction.none:
      break;
    case ContactsAccessAction.warn:
      debugPrint('[NightMail] contacts access lost ($permission) — warning');
      if (!context.mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showMaterialBanner(MaterialBanner(
        leading: const Icon(Icons.contacts_outlined),
        content: const Text(
          'NightMail can no longer read your Contacts, so their names are not '
          'suggested when you address mail. macOS can drop this permission '
          'when an app updates. Turn NightMail back on in System Settings → '
          'Privacy & Security → Contacts.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              // A reader who meant to revoke it is not asked again.
              unawaited(settings.saveContactsAccessGranted(false));
              messenger.hideCurrentMaterialBanner();
            },
            child: const Text("Don't remind me"),
          ),
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              unawaited(launchUrl(Uri.parse(_contactsPrivacyPane)));
            },
            child: const Text('Open System Settings'),
          ),
        ],
      ));
  }
}
