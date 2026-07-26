import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/inline_attachment.dart';

/// On-disk cache for an email's inline (`cid:`) images and the rendered
/// document that references them.
///
/// Why this exists: inlining the images as base64 `data:` URLs pushes the
/// document past WebView2's `NavigateToString` cap (~2 MB) and the page then
/// silently fails to load — a newsletter with a dozen embedded charts renders
/// as an empty reading pane on Windows. Writing the images to disk and loading
/// the document with `loadUrl` keeps the document small (relative `<img src>`)
/// however many megabytes of images an email carries, and skips the 33% base64
/// inflation on every platform.
///
/// Layout — one flat directory per email, because macOS `loadFileURL` only
/// grants read access to the document's *own* directory (the same constraint
/// `OfficePreviewService` works around by copying its JS libs next to the
/// generated viewer):
///
/// ```
/// <temp>/nightmail_inline/<sha256(emailId)>/
///     <sha256(bytes)>.png       ← inline image, content-addressed
///     page_<sha256(html)>.html  ← the document, content-addressed
/// ```
///
/// Both filenames are content hashes, so a file that is already present is
/// guaranteed to hold the right bytes and can be reused as-is on later views
/// and across app restarts. The directory name is hashed too, so IMAP ids like
/// `INBOX:1234` — whose `:` is illegal in a Windows path — are safe.
///
/// Entries are removed by [evictEmail] when the email leaves the local cache,
/// by [clear] when an account is removed, and by [prune] on startup for
/// anything left behind (an email whose id was remapped by a server-side move,
/// say).
class InlineAttachmentCache {
  /// [root] bypasses `getTemporaryDirectory()`, which is unavailable under the
  /// test binding on the platforms whose path_provider implementation is
  /// Dart-only rather than a mockable method channel.
  InlineAttachmentCache({@visibleForTesting Directory? root})
      : _rootCache = root;

  static const String _rootName = 'nightmail_inline';

  /// Documents at or above this size must be loaded from a file. WebView2's
  /// `NavigateToString` rejects anything over 2 MB outright; we leave headroom
  /// because the limit applies after UTF-8 encoding.
  static const int maxInlineDocumentBytes = 1536 * 1024;

  static final String _sep = Platform.pathSeparator;

  Directory? _rootCache;
  bool _rootUnavailable = false;

  /// Absolute path of an email's cache directory. Exposed so tests can assert
  /// on eviction without reimplementing the hashing.
  @visibleForTesting
  Future<String?> directoryPathFor(String cacheKey) async =>
      (await _dirFor(cacheKey, create: false))?.path;

  Future<Directory?> _root() async {
    final cached = _rootCache;
    if (cached != null) return cached;
    // No temp directory (a headless test binding, a locked-down sandbox) —
    // every entry point degrades to a no-op, so only report it once.
    if (_rootUnavailable) return null;
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory('${tmp.path}$_sep$_rootName');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _rootCache = dir;
      return dir;
    } catch (e) {
      _rootUnavailable = true;
      debugPrint('InlineAttachmentCache: cannot open cache root: $e');
      return null;
    }
  }

  static String _hash(List<int> bytes) => sha256.convert(bytes).toString();

  static String _dirNameFor(String cacheKey) =>
      _hash(utf8.encode(cacheKey)).substring(0, 32);

  Future<Directory?> _dirFor(String cacheKey, {required bool create}) async {
    final root = await _root();
    if (root == null) return null;
    final dir = Directory('${root.path}$_sep${_dirNameFor(cacheKey)}');
    if (create && !dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } catch (e) {
        debugPrint('InlineAttachmentCache: cannot create $cacheKey dir: $e');
        return null;
      }
    }
    return dir;
  }

  /// Writes any of [attachments] not already on disk into [cacheKey]'s
  /// directory and returns a map of `cid` token -> `file:` URL, suitable for
  /// rewriting `src="cid:…"` references.
  ///
  /// Absolute URLs rather than bare filenames: an email carrying its own
  /// `<base href>` would otherwise resolve the images against the sender's
  /// site instead of the cache directory. [Uri.file] also handles the
  /// percent-encoding a Windows temp path under a user folder with spaces
  /// needs.
  ///
  /// Both the full content id and — for Gmail's `<ii_x@mail.gmail.com>` form,
  /// where the body references only `cid:ii_x` — its local part are mapped to
  /// the same file. Returns null when the directory could not be prepared, so
  /// the caller can fall back to inlining as `data:` URLs.
  Future<Map<String, String>?> materialize({
    required String cacheKey,
    required List<InlineAttachment> attachments,
  }) async {
    if (attachments.isEmpty) return const <String, String>{};
    final dir = await _dirFor(cacheKey, create: true);
    if (dir == null) return null;

    final mapping = <String, String>{};
    for (final attachment in attachments) {
      final name = '${_hash(attachment.contentBytes)}'
          '.${_extensionFor(attachment.contentType)}';
      final file = File('${dir.path}$_sep$name');
      try {
        // The name is a hash of the bytes, so an existing file of the right
        // length already holds exactly this content — no need to rewrite it.
        if (!file.existsSync() ||
            file.lengthSync() != attachment.contentBytes.length) {
          await file.writeAsBytes(attachment.contentBytes, flush: true);
        }
      } catch (e) {
        debugPrint('InlineAttachmentCache: write failed for $name: $e');
        return null;
      }

      final url = Uri.file(file.path).toString();
      final cid = attachment.contentId;
      final bare = cid.startsWith('<') && cid.endsWith('>')
          ? cid.substring(1, cid.length - 1)
          : cid;
      mapping[bare] = url;
      final at = bare.indexOf('@');
      if (at != -1) mapping[bare.substring(0, at)] = url;
    }
    return mapping;
  }

  /// Writes [html] into [cacheKey]'s directory — the same one [materialize]
  /// writes to, because macOS `loadFileURL` grants read access to the
  /// document's own directory and nothing else — and returns its absolute
  /// path, or null on failure.
  Future<String?> writeDocument({
    required String cacheKey,
    required String html,
  }) async {
    final dir = await _dirFor(cacheKey, create: true);
    if (dir == null) return null;

    final bytes = utf8.encode(html);
    final file =
        File('${dir.path}${_sep}page_${_hash(bytes).substring(0, 16)}.html');
    try {
      if (file.existsSync() && file.lengthSync() == bytes.length) {
        // Identical document already cached. Touch it so [prune] treats the
        // whole entry as recently used rather than ageing it out.
        file.setLastModifiedSync(DateTime.now());
      } else {
        await file.writeAsBytes(bytes, flush: true);
      }
      return file.path;
    } catch (e) {
      debugPrint('InlineAttachmentCache: document write failed: $e');
      return null;
    }
  }

  /// Removes everything cached for [cacheKey]. Called when the email is
  /// deleted from — or otherwise leaves — the local cache.
  Future<void> evictEmail(String cacheKey) async {
    final dir = await _dirFor(cacheKey, create: false);
    if (dir == null || !dir.existsSync()) return;
    try {
      await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('InlineAttachmentCache: evict failed for $cacheKey: $e');
    }
  }

  /// Empties the cache entirely. Called on account removal — the cache is
  /// keyed by email id alone, so there is no per-account subset to target, and
  /// dropping the lot only costs a re-write on next view.
  Future<void> clear() async {
    final root = await _root();
    if (root == null || !root.existsSync()) return;
    try {
      await root.delete(recursive: true);
      root.createSync(recursive: true);
    } catch (e) {
      debugPrint('InlineAttachmentCache: clear failed: $e');
    }
  }

  /// Deletes entries untouched for longer than [maxAge]. Catches directories
  /// orphaned by an email id the server reassigned during a move, which
  /// [evictEmail] cannot know about.
  Future<void> prune({Duration maxAge = const Duration(days: 30)}) async {
    final root = await _root();
    if (root == null || !root.existsSync()) return;
    final cutoff = DateTime.now().subtract(maxAge);
    try {
      for (final entry in root.listSync()) {
        if (entry is! Directory) continue;
        try {
          if (_lastUsed(entry)?.isBefore(cutoff) ?? true) {
            entry.deleteSync(recursive: true);
          }
        } catch (_) {
          // Busy or vanished mid-sweep — leave it for the next run.
        }
      }
    } catch (e) {
      debugPrint('InlineAttachmentCache: prune failed: $e');
    }
  }

  /// Newest mtime among [dir]'s files. Directory mtimes are not updated by
  /// reads on any of our platforms, and [writeDocument] touches the document
  /// on a cache hit, so this is what tracks actual use.
  static DateTime? _lastUsed(Directory dir) {
    DateTime? newest;
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final stamp = f.statSync().modified;
      if (newest == null || stamp.isAfter(newest)) newest = stamp;
    }
    return newest;
  }

  /// Extension for [contentType], used because `file://` subresources are
  /// MIME-typed from the filename rather than sniffed.
  static String _extensionFor(String contentType) {
    final mime = contentType.split(';').first.trim().toLowerCase();
    switch (mime) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/gif':
        return 'gif';
      case 'image/webp':
        return 'webp';
      case 'image/svg+xml':
        return 'svg';
      case 'image/bmp':
        return 'bmp';
      case 'image/avif':
        return 'avif';
      case 'image/tiff':
        return 'tiff';
      case 'image/x-icon':
      case 'image/vnd.microsoft.icon':
        return 'ico';
    }
    final slash = mime.indexOf('/');
    if (slash == -1) return 'bin';
    final subtype = mime.substring(slash + 1).replaceAll(RegExp(r'[^a-z0-9]'), '');
    return subtype.isEmpty ? 'bin' : subtype;
  }
}
