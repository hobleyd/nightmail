import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_notes.dart';

void main() {
  group('buildReleaseNotes — conventional commits to hosted notes', () {
    test('groups by type, in feat → fix → perf → security order', () {
      final doc = buildReleaseNotes(
        version: '1.21.0',
        subjects: [
          'fix(mail): a blocked remote image left a hole',
          'feat(accounts): add account migration',
          'perf(cache): keep bodies off the listing path',
          'fix(imap): mangled 8-bit bodies',
        ],
      );

      expect(doc['version'], '1.21.0');
      expect(doc['schemaVersion'], 1);
      expect(doc['format'], 'desktop_updater.release_notes.v1');

      final sections = doc['sections']! as List;
      expect(
        sections.map((s) => (s as Map)['type']),
        ['features', 'fixes', 'performance'],
      );

      final fixes = sections[1] as Map;
      expect((fixes['items']! as List), hasLength(2));
    });

    test('the scope becomes the item title, and is omitted when absent', () {
      final doc = buildReleaseNotes(
        version: '1.0.0',
        subjects: ['fix(mail): scoped', 'fix: unscoped'],
      );

      final items = ((doc['sections']! as List).single as Map)['items']! as List;
      expect((items[0] as Map)['title'], 'mail');
      expect((items[0] as Map)['body'], 'scoped');
      expect((items[1] as Map).containsKey('title'), isFalse);
    });

    test('housekeeping types never reach the user', () {
      // A version bump and a test rename are not "what changed for you".
      final doc = buildReleaseNotes(
        version: '1.0.0',
        subjects: [
          'chore(version): bump to 1.20.0+17 (minor)',
          'docs(test): put the banner back',
          'ci: tweak the workflow',
          'build(deps): bump something',
          'style: reformat',
          'test: add a case',
        ],
      );

      expect(doc['sections'], isEmpty);
    });

    test('a non-conventional subject is dropped rather than guessed at', () {
      final doc = buildReleaseNotes(
        version: '1.0.0',
        subjects: ['Merge branch main', 'wip', 'feat(x): kept'],
      );

      final items = ((doc['sections']! as List).single as Map)['items']! as List;
      expect(items, hasLength(1));
      expect((items.single as Map)['body'], 'kept');
    });

    test('a breaking change is lifted out of its type into its own section',
        () {
      final doc = buildReleaseNotes(
        version: '2.0.0',
        subjects: [
          'feat(api)!: drop the v1 endpoint',
          'feat(mail): an ordinary feature',
        ],
      );

      final sections = doc['sections']! as List;
      // Breaking changes come first — it is the thing most easily missed.
      expect((sections.first as Map)['type'], 'breaking');
      expect(
        (((sections.first as Map)['items']! as List).single as Map)['body'],
        'drop the v1 endpoint',
      );
      expect((sections[1] as Map)['type'], 'features');
    });

    test('a breaking change with no scope still files correctly', () {
      final doc = buildReleaseNotes(
        version: '2.0.0',
        subjects: ['fix!: changed the on-disk format'],
      );
      expect(((doc['sections']! as List).single as Map)['type'], 'breaking');
    });

    test('no commits yields a valid, empty document', () {
      final doc = buildReleaseNotes(version: '1.0.1', subjects: []);
      expect(doc['sections'], isEmpty);
      expect(doc['version'], '1.0.1');
    });
  });
}
