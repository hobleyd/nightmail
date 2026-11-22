import 'package:flutter/material.dart';

import '../../core/error/failures.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/cloud_file.dart';
import '../../domain/usecases/cloud_files.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../injection_container.dart';
import 'adaptive_alert_dialog.dart';

/// The send-time half of "Link from Cloud": before a message carrying links to
/// cloud files goes, make sure its recipients can open them.
///
/// Checked at send rather than when the link is inserted because that is when
/// the recipients are known — a link usually goes in before the To line is
/// finished — and a recipient added afterwards is exactly the one who would be
/// missed.
///
/// [links] maps each URL the compose form inserted to the file it names. Links
/// the sender has since deleted from [html] are not checked.
///
/// Returns the HTML to send — with a link swapped for the file's existing
/// "anyone with the link" URL where it has one, since that opens for every
/// recipient — or null to stay in the editor. A check that fails (offline, the
/// provider erroring) never holds the message back: the link goes as it is.
Future<String?> prepareCloudLinksForSend({
  required BuildContext context,
  required String html,
  required Map<String, CloudFile> links,
  required List<String> recipients,
  required Future<T?> Function<T>(Future<T?> Function() dialog) showOverEditor,
  required void Function(String message) showNotice,
}) async {
  final present = {
    for (final entry in links.entries)
      if (_bodyLinksTo(html, entry.key)) entry.key: entry.value,
  };
  if (present.isEmpty || recipients.isEmpty) return html;

  var body = html;
  final blocked = <_Blocked>[];
  for (final MapEntry(key: url, value: file) in present.entries) {
    final result = await sl<CheckCloudFileAccess>()(file, recipients);
    result.match(
      (failure) => debugPrint('[CloudFiles] access check for ${file.name} '
          'failed (${failure.runtimeType}); sending the link as it is'),
      (access) {
        final anyone = access.anyoneLinkUrl;
        if (anyone != null && anyone != url) body = _replaceHref(body, url, anyone);
        if (access.recipientsWithoutAccess.isNotEmpty) {
          blocked.add(_Blocked(file, access.recipientsWithoutAccess,
              canShare: access.canShare));
        }
      },
    );
  }
  if (blocked.isEmpty) return body;
  if (!context.mounted) return null;

  final choice = await showOverEditor<_Choice>(() => showDialog<_Choice>(
        context: context,
        builder: (_) => _AccessDialog(blocked: blocked),
      ));
  switch (choice) {
    case null || _Choice.cancel:
      return null;
    case _Choice.sendAnyway:
      return body;
    case _Choice.share:
      final ok = await _share(blocked, showNotice);
      return ok ? body : null;
  }
}

/// Grants each blocked recipient read access, asking the account for the
/// write scope first where it has not been granted (a browser sign-in).
/// Returns false — with a notice saying what failed — when anything could not
/// be shared, so the sender decides again rather than sending a link someone
/// cannot open.
Future<bool> _share(
    List<_Blocked> blocked, void Function(String) showNotice) async {
  final accounts = sl<AccountManager>();
  final failures = <String>[];
  final granted = <String, bool>{};
  for (final item in blocked.where((b) => b.canShare)) {
    final accountId = item.file.accountId;
    var mayShare = granted[accountId] ??=
        await accounts.hasCloudDriveShareAccess(accountId);
    if (!mayShare) {
      try {
        mayShare = granted[accountId] =
            await accounts.requestCloudDriveShareAccess(accountId);
      } catch (e) {
        debugPrint('[CloudFiles] share grant for $accountId failed: $e');
        mayShare = granted[accountId] = false;
      }
    }
    if (!mayShare) {
      failures.add('NightMail was not allowed to share ${item.file.name}');
      continue;
    }
    final result = await sl<ShareCloudFile>()(item.file, item.recipients);
    result.match(
      (failure) => failures.add(
          "Couldn't share ${item.file.name}: ${_describe(failure)}"),
      (shared) {
        for (final MapEntry(key: who, value: why) in shared.failed.entries) {
          failures.add("Couldn't share ${item.file.name} with $who: $why");
        }
      },
    );
  }
  if (failures.isEmpty) return true;
  showNotice('${failures.join('\n')}\nSend again to choose whether to send '
      'anyway.');
  return false;
}

String _describe(Failure failure) => switch (failure) {
      NetworkFailure() => "you're offline",
      _ => failure.message,
    };

/// Whether [html] still holds a link to [url]. The editor serialises `&` in
/// an attribute as `&amp;`, so both spellings are looked for.
bool _bodyLinksTo(String html, String url) =>
    html.contains('href="$url"') ||
    html.contains('href="${_escapeAttr(url)}"');

String _replaceHref(String html, String from, String to) => html
    .replaceAll('href="$from"', 'href="${_escapeAttr(to)}"')
    .replaceAll('href="${_escapeAttr(from)}"', 'href="${_escapeAttr(to)}"');

String _escapeAttr(String value) =>
    value.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

class _Blocked {
  _Blocked(this.file, this.recipients, {required this.canShare});
  final CloudFile file;
  final List<String> recipients;
  final bool canShare;
}

enum _Choice { cancel, sendAnyway, share }

class _AccessDialog extends StatelessWidget {
  const _AccessDialog({required this.blocked});

  final List<_Blocked> blocked;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final shareable = blocked.where((b) => b.canShare).toList();
    final unshareable = blocked.where((b) => !b.canShare).toList();
    final style = TextStyle(color: c.textBody, fontSize: 13);
    return AdaptiveAlertDialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      title: Text(
        blocked.length == 1
            ? 'Not everyone can open ${blocked.single.file.name}'
            : 'Not everyone can open the linked files',
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final item in blocked) ...[
                if (blocked.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(item.file.name,
                        style: style.copyWith(
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary)),
                  ),
                Text(
                  blocked.length > 1
                      ? "Can't open it: ${item.recipients.join(', ')}"
                      : "These recipients can't open it: "
                          '${item.recipients.join(', ')}',
                  style: style,
                ),
                const SizedBox(height: 6),
              ],
              if (unshareable.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'You can\'t share '
                  '${unshareable.map((b) => b.file.name).join(', ')} — '
                  'ask its owner to.',
                  style: style.copyWith(color: c.textTertiary, fontSize: 12),
                ),
              ],
              if (shareable.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Sharing gives them view-only access. You may be asked to '
                  'sign in once so NightMail can share files.',
                  style: style.copyWith(color: c.textTertiary, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_Choice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_Choice.sendAnyway),
          child: const Text('Send anyway'),
        ),
        if (shareable.isNotEmpty)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_Choice.share),
            child: const Text('Share and send'),
          ),
      ],
    );
  }
}
