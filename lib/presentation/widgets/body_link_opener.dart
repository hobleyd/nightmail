import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../core/utils/cloud_document_link.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../injection_container.dart';
import '../../core/utils/online_meeting_url.dart';
import '../pages/compose_window.dart';
import 'cloud_document_preview_host.dart';

/// Opens a link the reader clicked in a message body.
///
/// Most links are somebody else's to open, and go to the OS. Two are answered
/// here instead:
///
/// * A `mailto:` is composed in NightMail's own window: this *is* the mail
///   application, and handing the URI out would post it to whatever the default
///   handler happens to be — another client, or NightMail again by way of the
///   OS, a round trip through a second process to arrive where the click
///   already was. On a machine where NightMail is not the default, it would
///   compose the reply in a program the reader did not choose.
/// * A **SharePoint/OneDrive, Google Drive or NightMail Server (Nextcloud)
///   document** is fetched and shown in the reading pane, the same surface an
///   attachment chip previews into — the
///   link is an attachment in all but name, and following it to a browser tab
///   asks the reader to sign in to a second thing to read their own mail. This
///   needs somewhere to draw the preview, so it only happens where a
///   [CloudDocumentPreviewHost] is in scope, and falls back to the browser
///   whenever the host declines (see [CloudDocumentPreviewHost.onPreview]).
///
/// The two body renderers share nothing else, but they both reach this: an
/// anchor in the webview (whose native views already cancel the navigation and
/// report the URL) and a linkified span in the plain text view.
Future<void> openBodyLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  if (uri.isScheme('mailto')) {
    return ComposeWindowApp.openMailto(context, uri);
  }

  final fileSites = _nextcloudFileSites();
  final document =
      parseCloudDocumentLink(url, nextcloudBaseUrls: fileSites);
  if (document != null) {
    final host = CloudDocumentPreviewHost.maybeOf(context);
    if (host == null) {
      debugPrint('[CloudPreview] ${document.provider.name} link, but no '
          'preview host here (standalone window?) — opening in the browser');
    } else if (await host(document)) {
      return;
    } else {
      debugPrint('[CloudPreview] ${document.provider.name} link declined '
          '— opening in the browser');
    }
  } else if (uri.isScheme('http') || uri.isScheme('https')) {
    // Host and path only: the query of an arbitrary link can carry a token.
    debugPrint('[CloudPreview] not a cloud-document link: '
        '${uri.host}${uri.path} (file sites known: ${fileSites.join(', ')})');
  }

  await launchWebUrl(uri);
}

/// The file sites signed-in NightMail Servers advertise. A sub-window engine
/// that never registered the account manager has none — and no preview host
/// either, so its links go to the browser regardless.
Iterable<String> _nextcloudFileSites() => sl.isRegistered<AccountManager>()
    ? sl<AccountManager>().nextcloudFileBaseUrls
    : const [];

/// Opens a web page the way the platform expects: in the in-app browser view
/// on a phone or tablet (Safari View Controller on iOS, a Custom Tab on
/// Android), so the reader comes straight back to the message when they are
/// done, and in the default browser on the desktop, where a separate browser
/// window is the norm. Anything that is not http(s) goes to whatever the OS
/// has registered for it.
Future<void> launchWebUrl(Uri uri) {
  final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  final web = uri.isScheme('http') || uri.isScheme('https');
  return launchUrl(
    uri,
    mode: mobile && web
        ? LaunchMode.inAppBrowserView
        : LaunchMode.externalApplication,
  );
}

/// Joins an online meeting, in the meeting's own app when it is installed.
///
/// The https join link alone opens a browser tab whose launcher page then hands
/// off to Teams, leaving the tab behind. Where the app can be reached directly
/// it is, and the web link is only the fallback:
///
/// * **macOS / Windows** — the app's `msteams:` scheme ([teamsAppJoinUrl]),
///   checked with `canLaunch` first so Windows does not offer to find a Store
///   app for a scheme nobody has registered.
/// * **iOS / Android** — the https link itself, restricted to a non-browser
///   handler: the Teams app claims those links as universal/app links, and the
///   launch reports false when it is not installed.
///
/// The fallback is the same external launch the join buttons always used, not
/// [launchWebUrl]'s in-app browser view — a meeting is not a page to read.
Future<void> launchMeetingJoinUrl(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return;

  if (!kIsWeb && (Platform.isMacOS || Platform.isWindows)) {
    final app = teamsAppJoinUrl(url);
    if (app != null) {
      try {
        if (await canLaunchUrlString(app) && await launchUrlString(app)) return;
      } catch (e) {
        debugPrint('[Meeting] msteams launch failed, using the web link: $e');
      }
    }
  } else if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
    if (teamsAppJoinUrl(url) != null) {
      try {
        if (await launchUrl(
          uri,
          mode: LaunchMode.externalNonBrowserApplication,
        )) {
          return;
        }
      } catch (e) {
        debugPrint('[Meeting] Teams app launch failed, using the web link: $e');
      }
    }
  }

  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
