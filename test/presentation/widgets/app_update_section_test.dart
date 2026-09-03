import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/update/app_update_status.dart';
import 'package:nightmail/presentation/widgets/app_update_section.dart';

/// A release with something to say, so nothing is dropped for being empty.
UpdateReleaseNotes _release(String version) => UpdateReleaseNotes(
      version: version,
      sections: [
        UpdateNoteSection(
          title: 'Fixes',
          items: [UpdateNoteItem(body: 'something in $version')],
        ),
      ],
    );

void main() {
  // Newest first, as the hosted document publishes them.
  final published = [
    _release('1.22.4'),
    _release('1.22.3'),
    _release('1.22.2'),
    _release('1.22.1'),
  ];

  group('which releases the About panel draws', () {
    test('every version published since the running build', () {
      // The point of the whole thing: a reader who skipped 1.22.2 and 1.22.3
      // sees what changed in each, not only in the release they are installing.
      expect(
        releaseNotesToShow(published, '1.22.1+150').map((r) => r.version),
        ['1.22.4', '1.22.3', '1.22.2'],
      );
    });

    test('the build number does not make a release look newer', () {
      // The installed version carries one and a release does not, so an
      // ordering that took build metadata into account would compare
      // 1.22.3+157 against 1.22.3 and offer the reader their own release.
      expect(
        releaseNotesToShow(published, '1.22.3+157').map((r) => r.version),
        ['1.22.4'],
      );
    });

    test('up to date shows the newest release rather than nothing', () {
      // The document describes the newest published release either way, and
      // without this the "What's new" block would vanish for anyone current.
      expect(
        releaseNotesToShow(published, '1.22.4+158').map((r) => r.version),
        ['1.22.4'],
      );
    });

    test('a build ahead of everything published still shows the newest', () {
      // A locally built app, which is routinely ahead of the archive.
      expect(
        releaseNotesToShow(published, '1.23.0+900').map((r) => r.version),
        ['1.22.4'],
      );
    });

    test('an unreadable installed version falls back to the newest', () {
      // Nothing can be placed against it, and dropping every release would
      // leave the panel emptier than it was before any of this.
      expect(releaseNotesToShow(published, null).map((r) => r.version),
          ['1.22.4']);
      expect(releaseNotesToShow(published, 'unknown').map((r) => r.version),
          ['1.22.4']);
    });

    test('a release naming no version is not drawn among dated ones', () {
      // It cannot be placed in the sequence, and guessing puts it in the wrong
      // half of "since your build".
      final notes = [
        _release('1.22.4'),
        UpdateReleaseNotes(sections: _release('1.22.3').sections),
      ];

      expect(releaseNotesToShow(notes, '1.22.2+156').map((r) => r.version),
          ['1.22.4']);
    });

    test('nothing fetched yet draws nothing', () {
      expect(releaseNotesToShow(const [], '1.22.3+157'), isEmpty);
    });
  });
}
