import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../injection_container.dart';
import 'adaptive_alert_dialog.dart';

/// Makes sure the active account can send a phishing report before one is
/// attempted, asking for Microsoft's scope the first time. Returns whether to
/// go ahead.
///
/// The scope (`ThreatSubmission.ReadWrite`) is requested here, in front of the
/// button that needs it, and never at sign-in — see
/// `MicrosoftAuthService.threatSubmissionScope` for why. The dialog says the
/// provider is about to ask *before* anything happens, the same shape as the
/// cloud-document and out-of-office consents, and a decline is an answer: the
/// message is left where it is and nothing is reported.
///
/// Gmail and IMAP have no report channel — reporting phishing there files the
/// message as junk, which needs nothing extra — so they always go ahead.
Future<bool> ensurePhishingReportAccess(BuildContext context) async {
  final accountManager = sl<AccountManager>();
  final account = accountManager.activeAccount;
  if (account is! MicrosoftAccount) return true;
  if (await accountManager.hasThreatSubmissionAccess(account.id)) return true;
  if (!context.mounted) return false;

  final c = context.colors;
  final agreed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AdaptiveAlertDialog(
      backgroundColor: c.surfacePanel,
      title: const Text('Report phishing to Microsoft?'),
      content: Text(
        'To send phishing reports to Microsoft, ${account.emailAddress} needs '
        'to grant NightMail permission to submit them on your behalf.\n\n'
        'You will be asked to sign in once. Your organisation may require an '
        'administrator to approve this permission.',
        style: TextStyle(color: c.textBody, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Grant access'),
        ),
      ],
    ),
  );
  if (agreed != true || !context.mounted) return false;

  try {
    final granted =
        await accountManager.requestThreatSubmissionAccess(account.id);
    if (!granted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Permission was not granted — the message has not been reported'),
      ));
    }
    return granted;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not grant access: $e')),
      );
    }
    return false;
  }
}
