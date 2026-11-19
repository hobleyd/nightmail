/// What asking one NightMail Server for its file sites again came to — see
/// `AccountManager.refreshServerFileSites`.
///
/// Every outcome says whether the server's accounts are left with no file site
/// at all ([previewsOff]): that, not the outcome itself, is what a reader
/// notices, because a server that could not be reached this time still has the
/// sites it published last time.
sealed class FileSitesRefresh {
  const FileSitesRefresh(this.serverUrl, {required this.previewsOff});

  final String serverUrl;

  /// No account on this server holds a file site afterwards, so links to its
  /// Nextcloud are not recognised and open in the browser.
  final bool previewsOff;
}

/// The server's accounts adopted the file sites it publishes now.
final class FileSitesUpdated extends FileSitesRefresh {
  const FileSitesUpdated(super.serverUrl, {required super.previewsOff});
}

/// The server publishes what its accounts already hold — possibly nothing.
final class FileSitesUnchanged extends FileSitesRefresh {
  const FileSitesUnchanged(super.serverUrl, {required super.previewsOff});
}

/// The discovery document could not be had; nothing was changed.
final class FileSitesUnreachable extends FileSitesRefresh {
  const FileSitesUnreachable(super.serverUrl,
      {required this.reason, required super.previewsOff});

  final String reason;
}

/// The server now answers with a different sign-in configuration ([changed]
/// names the discovery field), so nothing was adopted: that takes a fresh
/// sign-in, which re-adding the account does. This one never clears itself.
final class FileSitesRefused extends FileSitesRefresh {
  const FileSitesRefused(super.serverUrl,
      {required this.changed, required super.previewsOff});

  final String changed;
}
