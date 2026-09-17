import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/platform/app_data_directory.dart';

void main() {
  const home = '/Users/someone';

  group('macOSAppDataPathFor', () {
    test('redirects the real unsandboxed answer to ~/.nightmail', () {
      expect(
        macOSAppDataPathFor(
          supportPath: '$home/Library/Application Support/au.com.sharpblue.nightmail',
          home: home,
        ),
        '$home/.nightmail',
      );
    });

    test('redirects a sandboxed build too — its container is under Library', () {
      expect(
        macOSAppDataPathFor(
          supportPath:
              '$home/Library/Containers/au.com.sharpblue.nightmail/Data/Library/Application Support/au.com.sharpblue.nightmail',
          home: home,
        ),
        '$home/.nightmail',
      );
    });

    test('honours a path that is not the platform\'s own, which is what keeps '
        'a test faking PathProviderPlatform out of the real home directory', () {
      expect(
        macOSAppDataPathFor(supportPath: '/tmp/some_test_dir', home: home),
        isNull,
      );
    });

    test('leaves the support directory alone when HOME says nothing', () {
      expect(
        macOSAppDataPathFor(
          supportPath: '$home/Library/Application Support/x',
          home: null,
        ),
        isNull,
      );
      expect(
        macOSAppDataPathFor(
          supportPath: '$home/Library/Application Support/x',
          home: '',
        ),
        isNull,
      );
    });
  });
}
