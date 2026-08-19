// Builds the `release-notes.json` the About panel shows, from the conventional
// commit subjects between the previous release tag and this one.
//
// Run from the release workflow's deploy job:
//
//   dart run tool/release_notes.dart --version 1.21.0 --output deploy/release-notes.json
//
// Why generate rather than use GitHub's own notes: `generate_release_notes`
// builds its body out of *merged pull requests*, and this repository pushes
// straight to main, so that body comes back empty. The commit subjects are
// strictly conventional (`feat(scope): …`, `fix(scope): …`), which is exactly
// the structure the notes want, so they are the better source.
//
// The output is `desktop_updater`'s rich release-notes schema plus a top-level
// `version`, so it stays readable by that package's own bottom sheet.

import 'dart:convert';
import 'dart:io';

/// Conventional-commit types that reach the notes, mapped onto schema section
/// types, in the order the sections should appear.
///
/// `chore`, `docs`, `test`, `ci`, `build` and `style` are deliberately absent:
/// a release-notes list is what changed *for the user*, and a version bump or a
/// test rename is not that. An unrecognised type is dropped for the same
/// reason — silence is better than a section of noise.
const _sections = <String, ({String type, String title})>{
  'feat': (type: 'features', title: 'New features'),
  'fix': (type: 'fixes', title: 'Fixes'),
  'perf': (type: 'performance', title: 'Performance'),
  'security': (type: 'security', title: 'Security'),
};

/// `type(scope)!: subject` — scope and the breaking-change `!` both optional.
final _conventional = RegExp(r'^([a-z]+)(?:\(([^)]*)\))?(!)?:\s*(.+)$');

Future<int> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options == null) {
    stderr.writeln(
      'usage: dart run tool/release_notes.dart --version <v> '
      '[--output <path>] [--from <ref>] [--to <ref>]',
    );
    return 64;
  }

  final from = options.from ?? await _previousReleaseTag(options.version);
  final range = from == null ? options.to : '$from..${options.to}';

  final log = await _git(['log', '--no-merges', '--pretty=format:%s', range]);
  final subjects = log
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  final document = buildReleaseNotes(
    version: options.version,
    subjects: subjects,
  );
  final json = '${const JsonEncoder.withIndent('  ').convert(document)}\n';

  final output = options.output;
  if (output == null) {
    stdout.write(json);
  } else {
    final file = File(output);
    await file.parent.create(recursive: true);
    await file.writeAsString(json);
    stderr.writeln(
      'Wrote $output '
      '(${from ?? 'start of history'}..${options.to}, '
      '${subjects.length} commits).',
    );
  }
  return 0;
}

/// Groups conventional-commit [subjects] into the hosted notes document.
///
/// Kept separate from the IO above so it can be tested directly.
Map<String, Object?> buildReleaseNotes({
  required String version,
  required List<String> subjects,
}) {
  final buckets = <String, List<Map<String, Object?>>>{};
  final breaking = <Map<String, Object?>>[];

  for (final subject in subjects) {
    final match = _conventional.firstMatch(subject);
    if (match == null) continue;

    final type = match.group(1)!;
    final scope = match.group(2);
    final isBreaking = match.group(3) != null;
    final text = match.group(4)!.trim();
    if (text.isEmpty) continue;

    final item = <String, Object?>{
      'body': text,
      if (scope != null && scope.isNotEmpty) 'title': scope,
    };

    // A breaking change is filed under Breaking changes whatever its type: it
    // is the thing the reader most needs to see, and burying it among the
    // features is how it gets missed.
    if (isBreaking) {
      breaking.add(item);
      continue;
    }

    final section = _sections[type];
    if (section == null) continue;
    buckets.putIfAbsent(section.type, () => []).add(item);
  }

  final sections = <Map<String, Object?>>[
    if (breaking.isNotEmpty)
      {'type': 'breaking', 'title': 'Breaking changes', 'items': breaking},
    for (final entry in _sections.values)
      if (buckets[entry.type] case final items?)
        {'type': entry.type, 'title': entry.title, 'items': items},
  ];

  return <String, Object?>{
    'schemaVersion': 1,
    'format': 'desktop_updater.release_notes.v1',
    'version': version,
    'sections': sections,
  };
}

/// The release tag immediately before [version].
///
/// Tags are the plain semver the workflow pushes (`1.20.0`), so they sort by
/// version rather than by date — a rebuild of an older branch must not become
/// "the previous release". Returns null when this is the first release, in
/// which case the whole history is summarised.
Future<String?> _previousReleaseTag(String version) async {
  final output = await _git(['tag', '--list', '--sort=-v:refname']);
  final tags = output
      .split('\n')
      .map((line) => line.trim())
      .where((line) => RegExp(r'^v?\d+\.\d+\.\d+$').hasMatch(line))
      .toList();

  final current = _normalise(version);
  for (final tag in tags) {
    if (_compare(_normalise(tag), current) < 0) return tag;
  }
  return null;
}

List<int> _normalise(String version) {
  final cleaned = version.startsWith('v') ? version.substring(1) : version;
  return cleaned.split('.').map((part) => int.tryParse(part) ?? 0).toList();
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (left != right) return left.compareTo(right);
  }
  return 0;
}

Future<String> _git(List<String> args) async {
  final result = await Process.run('git', args);
  if (result.exitCode != 0) {
    // A missing range is normal on a shallow clone or a first release; an empty
    // log yields an empty notes document rather than failing the deploy.
    stderr.writeln('git ${args.join(' ')} failed: ${result.stderr}');
    return '';
  }
  return (result.stdout as String).trim();
}

({String version, String? output, String? from, String to})? _parseArgs(
  List<String> args,
) {
  String? version;
  String? output;
  String? from;
  var to = 'HEAD';

  for (var i = 0; i < args.length; i++) {
    final next = i + 1 < args.length ? args[i + 1] : null;
    switch (args[i]) {
      case '--version':
        version = next;
        i++;
      case '--output':
        output = next;
        i++;
      case '--from':
        from = next;
        i++;
      case '--to':
        to = next ?? 'HEAD';
        i++;
      default:
        return null;
    }
  }

  if (version == null || version.isEmpty) return null;
  return (version: version, output: output, from: from, to: to);
}
