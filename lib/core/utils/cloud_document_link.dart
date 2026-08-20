/// Telling a link to a cloud *document* apart from every other link in a body.
///
/// A SharePoint/OneDrive or Google Drive link in a message points at a file the
/// reader almost certainly wants to look at, not a web page they want to visit
/// — so NightMail fetches it and previews it in the reading pane, the same way
/// an attachment chip does. Everything else keeps going to the browser.
///
/// **This scanner is deliberately biased towards not matching.** A false
/// positive is the expensive mistake: a SharePoint *site* link or a Drive
/// *folder* link opens fine in a browser today, and turning one into an
/// in-app preview attempt replaces that with a spinner and an apology. So the
/// exclusions below are as load-bearing as the patterns — anything not
/// recognised as a single document falls through to `launchUrl` unchanged.
///
/// Which mailbox the link arrived in says nothing about which service holds
/// the file: a OneDrive link routinely turns up in Gmail and a Drive link in
/// Exchange. The provider is read off the *URL*, and the account that fetches
/// it is chosen later from whoever is signed in to that service.
library;

import '../../domain/entities/cloud_document.dart';

/// Hosts that serve Microsoft 365 files. `*.sharepoint.com` covers both
/// SharePoint document libraries and OneDrive for Business (which lives on the
/// tenant's `-my.sharepoint.com` host).
///
/// Consumer OneDrive (`onedrive.live.com`, and the `1drv.ms` shortener) is left
/// out on purpose. Graph's `/shares` does resolve those URLs — Microsoft's own
/// worked example is one — but the accounts NightMail signs in are work
/// accounts whose token has no standing in somebody's personal OneDrive, and an
/// anonymous share link is readable in a browser with no token at all. Fetching
/// it here would mean asking for a file permission to do worse than the
/// browser. Add them only alongside a personal-account path that has been tried
/// against a real link.
bool _isMicrosoftFileHost(String host) {
  return host == 'sharepoint.com' || host.endsWith('.sharepoint.com');
}

/// Path fragments that mean "this SharePoint URL is not a single file".
///
/// * `/:f:/` — a share link to a *folder* (the sharing-link type letter; `:w:`
///   is Word, `:x:` Excel, `:p:` PowerPoint, `:b:` PDF, `:u:`/`:t:` other).
/// * `/_layouts/` and `.aspx` — SharePoint's own application pages, including
///   `Forms/AllItems.aspx` library browsers and `SitePages` wiki pages.
/// * `/Lists/` — a SharePoint list, which has no file to download.
const _microsoftExclusions = <String>[
  '/:f:/',
  '/_layouts/',
  '/lists/',
  '.aspx',
];

/// Google hosts that address a specific document.
const _googleFileHosts = <String>{
  'drive.google.com',
  'docs.google.com',
};

/// The Google editor paths whose `/d/{id}/` segment names a file we can export.
/// `drawings` is included because it exports to PDF like the rest; `forms` is
/// not — a form is a web app, and its `/d/e/` "published" form ids are not
/// file ids at all.
const _googleEditorKinds = <String>{
  'document',
  'spreadsheets',
  'presentation',
  'drawings',
};

/// Recognises a link to a cloud document, or returns null to leave it to the
/// browser.
///
/// [url] is the raw href as it appeared in the message body.
CloudDocumentLink? parseCloudDocumentLink(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  if (!uri.hasScheme || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return null;

  if (_isMicrosoftFileHost(host)) return _parseMicrosoft(uri);
  if (_googleFileHosts.contains(host)) return _parseGoogle(uri);
  return null;
}

/// SharePoint and OneDrive for Business.
///
/// No id is extracted: Graph resolves a *sharing URL* directly
/// (`/shares/{u!encoded}/driveItem`), which is the only route that works for
/// all of the shapes these links come in — `/:w:/g/personal/…/Ee7…` share
/// links, `/:x:/r/sites/…/Doc.xlsx?d=w…` redirect links, and plain
/// `/sites/Team/Shared%20Documents/Doc.docx` library paths alike. Picking an id
/// out of any one of them by hand would only cover that one.
CloudDocumentLink? _parseMicrosoft(Uri uri) {
  final path = uri.path.toLowerCase();

  // A bare host, or a site root with nothing addressed under it, is a place
  // rather than a document.
  if (path.isEmpty || path == '/') return null;

  for (final fragment in _microsoftExclusions) {
    if (path.contains(fragment)) return null;
  }

  // A tenant's site or personal-site root: `/sites/Team`, `/personal/a_b_com`,
  // `/teams/Group`. There is a document *library* under these, not a document.
  final segments =
      uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  if (segments.length <= 2 &&
      const {'sites', 'teams', 'personal'}.contains(
        segments.isEmpty ? '' : segments.first.toLowerCase(),
      )) {
    return null;
  }

  return CloudDocumentLink(
    provider: CloudDriveProvider.microsoft,
    url: uri.toString(),
  );
}

/// Google Drive and the Docs/Sheets/Slides editors.
CloudDocumentLink? _parseGoogle(Uri uri) {
  final segments =
      uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
  if (segments.isEmpty) {
    // `drive.google.com/open?id=…` and `drive.google.com/uc?id=…` address a
    // file with no path at all.
    return _fromGoogleQuery(uri);
  }

  final first = segments.first.toLowerCase();

  // `/drive/folders/{id}` is a folder; `/drive/u/0/…` and `/drive/my-drive`
  // are the Drive web UI. Neither is a document — but `/drive/u/0/open?id=…`
  // is, so the query form still gets its chance.
  //
  // `/open` and `/uc` carry the file in `?id=` and have no id in the path.
  if (first == 'drive' || first == 'open' || first == 'uc') {
    return _fromGoogleQuery(uri);
  }

  // `/file/d/{id}/view`
  if (first == 'file') {
    final id = _idAfterD(segments);
    return id == null
        ? null
        : CloudDocumentLink(
            provider: CloudDriveProvider.google,
            url: uri.toString(),
            fileId: id,
          );
  }

  // `/document/d/{id}/edit`, `/spreadsheets/d/{id}`, `/presentation/d/{id}`.
  if (_googleEditorKinds.contains(first)) {
    // `/d/e/2PACX-…` is a *published* document — that long id is a publishing
    // token, not a file id, and Drive cannot export it. It is already a
    // readable web page, so the browser is the right answer.
    if (segments.length > 2 && segments[1].toLowerCase() == 'd' &&
        segments[2].toLowerCase() == 'e') {
      return null;
    }
    final id = _idAfterD(segments);
    return id == null
        ? null
        : CloudDocumentLink(
            provider: CloudDriveProvider.google,
            url: uri.toString(),
            fileId: id,
          );
  }

  return null;
}

/// The `?id=` form, used by `drive.google.com/open`, `/uc` and `/thumbnail`.
CloudDocumentLink? _fromGoogleQuery(Uri uri) {
  final id = uri.queryParameters['id'];
  if (id == null || !_isPlausibleFileId(id)) return null;
  return CloudDocumentLink(
    provider: CloudDriveProvider.google,
    url: uri.toString(),
    fileId: id,
  );
}

/// The segment after `/d/`, which is where every editor and Drive file URL
/// carries its file id.
String? _idAfterD(List<String> segments) {
  for (var i = 0; i < segments.length - 1; i++) {
    if (segments[i].toLowerCase() == 'd') {
      final id = segments[i + 1];
      return _isPlausibleFileId(id) ? id : null;
    }
  }
  return null;
}

/// Drive file ids are opaque, but they are always a run of URL-safe characters
/// of some length — checking that much keeps a stray `/d/edit` out.
bool _isPlausibleFileId(String id) {
  if (id.length < 8) return false;
  return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id);
}
