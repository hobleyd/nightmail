import 'dart:convert';

import 'package:dio/dio.dart';

import 'app_update_status.dart';

/// Reads the hosted `release-notes.json` that the release workflow generates.
///
/// **Both platforms read the same document.** `desktop_updater` has its own
/// release-notes machinery, but it only works when the controller is holding an
/// active descriptor — so it yields nothing on Android, and nothing on a machine
/// that is already up to date. The notes are wanted in both of those cases (the
/// About panel shows what is in the newest release either way), so the app
/// fetches the file itself and one implementation serves everything.
///
/// Nothing here is signature-verified, and deliberately so: the notes are text
/// shown to a human, never a decision the updater acts on. What gets installed
/// is chosen from the *signed* app-archive and release descriptor, which
/// `desktop_updater` verifies against the pinned Ed25519 keys.
///
/// The document is written in `desktop_updater`'s own rich schema so it stays
/// readable by the package's bottom sheet if this is ever handed back to it,
/// with one addition — a top-level `version` — naming the release it describes.
class ReleaseNotesFetcher {
  ReleaseNotesFetcher({required this.url, Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
                // Decoded here rather than by Dio: GitHub Pages serves this as
                // application/json, but a 404 page comes back as HTML and
                // jsonDecode is the thing that has to reject it.
                responseType: ResponseType.plain,
              ),
            );

  final Uri url;
  final Dio _dio;

  /// The releases the document describes, newest first.
  ///
  /// Empty when there is nothing to show; never null, so a caller cannot
  /// mistake "no notes" for "not fetched yet".
  Future<List<UpdateReleaseNotes>> fetch() async {
    final response = await _dio.getUri<String>(url);
    final body = response.data;
    if (body == null || body.trim().isEmpty) return const [];
    return parseReleaseNotesHistory(body);
  }
}

/// Section titles for the schema's normalised `type` values. A section that
/// carries its own `title` keeps it; these are the fallbacks.
const _sectionTitles = <String, String>{
  'features': 'New features',
  'feature': 'New features',
  'feat': 'New features',
  'fixes': 'Fixes',
  'fix': 'Fixes',
  'bugfix': 'Fixes',
  'bugfixes': 'Fixes',
  'security': 'Security',
  'breaking': 'Breaking changes',
  'breaking-changes': 'Breaking changes',
  'breaking_changes': 'Breaking changes',
  'performance': 'Performance',
  'perf': 'Performance',
  'other': 'Other changes',
  'chore': 'Other changes',
};

/// Parses either shape `desktop_updater` documents: the rich `sections` form
/// this app publishes, or the simple `{"data": [{type, message}]}` form. The
/// simple form is accepted so a hand-written file still renders.
///
/// Returns null rather than throwing on a document that parses but says
/// nothing — an empty notes file is a release with no user-visible changes, not
/// an error to report.
UpdateReleaseNotes? parseReleaseNotes(String body) =>
    _parseRelease(_decodeDocument(body));

/// Every release the document describes, newest first: the release at the top
/// level, then each entry of its `previous` array.
///
/// `previous` is an addition to `desktop_updater`'s schema, and both directions
/// degrade: a reader that does not know the key still shows the top-level
/// release, and a document published before the key existed yields a
/// single-entry list rather than failing.
///
/// A release carrying nothing to say is dropped rather than drawn as a bare
/// heading — which is how a version whose commits were all chores appears.
List<UpdateReleaseNotes> parseReleaseNotesHistory(String body) {
  final decoded = _decodeDocument(body);

  final releases = <UpdateReleaseNotes>[];
  final newest = _parseRelease(decoded);
  if (newest != null) releases.add(newest);

  final previous = decoded['previous'];
  if (previous is List) {
    for (final raw in previous) {
      if (raw is! Map) continue;
      final release = _parseRelease(Map<String, dynamic>.from(raw));
      if (release != null) releases.add(release);
    }
  }

  return List.unmodifiable(releases);
}

Map<String, dynamic> _decodeDocument(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('release-notes.json must be a JSON object.');
  }
  return decoded;
}

UpdateReleaseNotes? _parseRelease(Map<String, dynamic> decoded) {
  final version = _optionalString(decoded['version']);
  final summary = _optionalString(decoded['summary']);

  final sections = <UpdateNoteSection>[];

  final rawSections = decoded['sections'];
  if (rawSections is List) {
    for (final raw in rawSections) {
      if (raw is! Map) continue;
      final section = Map<String, dynamic>.from(raw);
      final rawItems = section['items'];
      if (rawItems is! List) continue;

      final items = <UpdateNoteItem>[];
      for (final rawItem in rawItems) {
        if (rawItem is! Map) continue;
        final item = Map<String, dynamic>.from(rawItem);
        final itemBody = _optionalString(item['body']);
        if (itemBody == null) continue;
        items.add(
          UpdateNoteItem(body: itemBody, title: _optionalString(item['title'])),
        );
      }
      if (items.isEmpty) continue;

      sections.add(
        UpdateNoteSection(
          title: _optionalString(section['title']) ??
              _titleForType(section['type']),
          items: items,
        ),
      );
    }
  }

  // The simple contributor-friendly shape: one flat list, grouped by type.
  final rawData = decoded['data'];
  if (sections.isEmpty && rawData is List) {
    final buckets = <String, List<UpdateNoteItem>>{};
    final order = <String>[];
    for (final raw in rawData) {
      if (raw is! Map) continue;
      final entry = Map<String, dynamic>.from(raw);
      final message = _optionalString(entry['message']);
      if (message == null) continue;
      final title = _titleForType(entry['type']);
      if (!buckets.containsKey(title)) order.add(title);
      buckets.putIfAbsent(title, () => []).add(UpdateNoteItem(body: message));
    }
    for (final title in order) {
      sections.add(UpdateNoteSection(title: title, items: buckets[title]!));
    }
  }

  final notes = UpdateReleaseNotes(
    version: version,
    summary: summary,
    sections: List.unmodifiable(sections),
  );
  return notes.isEmpty ? null : notes;
}

String _titleForType(Object? type) {
  final key = type?.toString().trim().toLowerCase();
  if (key == null || key.isEmpty) return _sectionTitles['other']!;
  return _sectionTitles[key] ?? _sectionTitles['other']!;
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
