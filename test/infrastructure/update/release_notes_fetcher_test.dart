import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/update/release_notes_fetcher.dart';

void main() {
  group('parseReleaseNotes — rich schema (what the workflow publishes)', () {
    test('reads version, summary, sections and item titles', () {
      final notes = parseReleaseNotes(jsonEncode({
        'schemaVersion': 1,
        'format': 'desktop_updater.release_notes.v1',
        'version': '1.21.0',
        'summary': 'Quality improvements.',
        'sections': [
          {
            'type': 'features',
            'title': 'New features',
            'items': [
              {'title': 'accounts', 'body': 'add account migration'},
            ],
          },
          {
            'type': 'fixes',
            'items': [
              {'body': 'a blocked remote image left a hole'},
            ],
          },
        ],
      }))!;

      expect(notes.version, '1.21.0');
      expect(notes.summary, 'Quality improvements.');
      expect(notes.sections, hasLength(2));

      expect(notes.sections[0].title, 'New features');
      expect(notes.sections[0].items.single.title, 'accounts');
      expect(notes.sections[0].items.single.body, 'add account migration');

      // A section with no title of its own falls back to one derived from
      // its type, so the panel never draws an unlabelled group.
      expect(notes.sections[1].title, 'Fixes');
      expect(notes.sections[1].items.single.title, isNull);
    });

    test('drops items with no body, and sections left empty by that', () {
      final notes = parseReleaseNotes(jsonEncode({
        'version': '2.0.0',
        'sections': [
          {
            'type': 'fixes',
            'items': [
              {'title': 'orphan'},
              {'body': '   '},
            ],
          },
          {
            'type': 'features',
            'items': [
              {'body': 'a real one'},
            ],
          },
        ],
      }))!;

      expect(notes.sections, hasLength(1));
      expect(notes.sections.single.title, 'New features');
    });

    test('an unknown section type still renders, under Other changes', () {
      final notes = parseReleaseNotes(jsonEncode({
        'sections': [
          {
            'type': 'wildly-unexpected',
            'items': [
              {'body': 'something'},
            ],
          },
        ],
      }))!;

      expect(notes.sections.single.title, 'Other changes');
    });
  });

  group('parseReleaseNotes — simple schema', () {
    test('groups a flat data list by type, in first-seen order', () {
      final notes = parseReleaseNotes(jsonEncode({
        'version': '1.0.0',
        'data': [
          {'type': 'fix', 'message': 'fixed one'},
          {'type': 'feat', 'message': 'added one'},
          {'type': 'fix', 'message': 'fixed two'},
        ],
      }))!;

      expect(notes.sections.map((s) => s.title), ['Fixes', 'New features']);
      expect(
        notes.sections.first.items.map((i) => i.body),
        ['fixed one', 'fixed two'],
      );
    });

    test('an entry with no recognised type lands in Other changes', () {
      final notes = parseReleaseNotes(jsonEncode({
        'data': [
          {'message': 'untyped'},
        ],
      }))!;

      expect(notes.sections.single.title, 'Other changes');
    });
  });

  group('parseReleaseNotes — nothing to say', () {
    test('a document with no items at all is null, not an empty panel', () {
      expect(parseReleaseNotes(jsonEncode({'version': '1.0.0'})), isNull);
      expect(parseReleaseNotes(jsonEncode({'sections': []})), isNull);
    });

    test('a summary alone is enough to be worth showing', () {
      final notes =
          parseReleaseNotes(jsonEncode({'summary': 'Security fixes.'}))!;
      expect(notes.summary, 'Security fixes.');
      expect(notes.sections, isEmpty);
    });

    test('a non-object document is rejected — a 404 HTML page arrives here', () {
      expect(() => parseReleaseNotes('<!doctype html><h1>404</h1>'),
          throwsA(isA<FormatException>()));
      expect(() => parseReleaseNotes('[]'), throwsA(isA<FormatException>()));
    });
  });
}
