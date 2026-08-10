import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../pages/compose_window.dart';

/// Opens a link the reader clicked in a message body.
///
/// Every link but one is somebody else's to open, and goes to the OS. A
/// `mailto:` is answered here instead, with NightMail's own compose window:
/// this *is* the mail application, and handing the URI out would post it to
/// whatever the default handler happens to be — another client, or NightMail
/// again by way of the OS, a round trip through a second process to arrive
/// where the click already was. On a machine where NightMail is not the
/// default, it would compose the reply in a program the reader did not choose.
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
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
