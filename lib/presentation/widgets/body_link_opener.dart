import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/utils/cloud_document_link.dart';
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
/// * A **SharePoint/OneDrive or Google Drive document** is fetched and shown in
///   the reading pane, the same surface an attachment chip previews into — the
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

  final document = parseCloudDocumentLink(url);
  if (document != null) {
    final host = CloudDocumentPreviewHost.maybeOf(context);
    if (host != null && await host(document)) return;
  }

  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
