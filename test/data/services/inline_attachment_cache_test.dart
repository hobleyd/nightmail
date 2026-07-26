import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/services/inline_attachment_cache.dart';
import 'package:nightmail/domain/entities/inline_attachment.dart';

InlineAttachment _png(String cid, List<int> bytes) => InlineAttachment(
      contentId: cid,
      contentType: 'image/png',
      contentBytes: Uint8List.fromList(bytes),
    );

void main() {
  late Directory root;
  late InlineAttachmentCache cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('inline_cache_test');
    cache = InlineAttachmentCache(root: root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<Directory> dirFor(String key) async =>
      Directory((await cache.directoryPathFor(key))!);

  File fileOf(String url) => File(Uri.parse(url).toFilePath());

  group('materialize', () {
    test('writes each attachment and maps its cid to a file URL', () async {
      final mapping = await cache.materialize(
        cacheKey: 'email-1',
        attachments: [
          _png('<img-a>', [1, 2, 3]),
          _png('<img-b>', [4, 5, 6, 7]),
        ],
      );

      expect(mapping, isNotNull);
      expect(mapping!.keys, containsAll(['img-a', 'img-b']));

      final dir = await dirFor('email-1');
      for (final url in mapping.values) {
        // Absolute, so an email's own <base href> cannot redirect them.
        expect(url, startsWith('file:'));
        expect(url, endsWith('.png'));
        final file = fileOf(url);
        expect(file.existsSync(), isTrue, reason: '$url should be on disk');
        expect(file.parent.path, dir.path);
      }
      expect(fileOf(mapping['img-a']!).readAsBytesSync(), [1, 2, 3]);
    });

    // Gmail sets Content-ID to `<ii_x@mail.gmail.com>` while the body
    // references only `cid:ii_x`, so both have to resolve to the same file.
    test('maps the local part of an addr-spec content id too', () async {
      final mapping = await cache.materialize(
        cacheKey: 'email-1',
        attachments: [_png('<ii_abc@mail.gmail.com>', [9])],
      );

      expect(mapping!['ii_abc@mail.gmail.com'], isNotNull);
      expect(mapping['ii_abc'], mapping['ii_abc@mail.gmail.com']);
    });

    test('names files by content hash, so identical bytes dedupe', () async {
      final mapping = await cache.materialize(
        cacheKey: 'email-1',
        attachments: [
          _png('<one>', [42, 42]),
          _png('<two>', [42, 42]),
        ],
      );

      expect(mapping!['one'], mapping['two']);
      expect((await dirFor('email-1')).listSync().whereType<File>().length, 1);
    });

    test('reuses an already-written file rather than rewriting it', () async {
      const attachments = 'email-1';
      final first = await cache.materialize(
        cacheKey: attachments,
        attachments: [_png('<one>', [1, 2, 3])],
      );
      final file = fileOf(first!['one']!);
      final stampBefore = file.statSync().modified;

      // A cache hit must not touch the image file — the name is a content
      // hash, so an existing file of the right length is already correct.
      final second = await cache.materialize(
        cacheKey: attachments,
        attachments: [_png('<one>', [1, 2, 3])],
      );

      expect(second!['one'], first['one']);
      expect(file.statSync().modified, stampBefore);
    });

    test('returns an empty map for no attachments', () async {
      expect(
        await cache.materialize(cacheKey: 'email-1', attachments: const []),
        isEmpty,
      );
    });
  });

  group('writeDocument', () {
    test('writes the document beside the images', () async {
      final mapping = await cache.materialize(
        cacheKey: 'email-1',
        attachments: [_png('<one>', [1])],
      );
      final path = await cache.writeDocument(
        cacheKey: 'email-1',
        html: '<img src="${mapping!['one']}">',
      );

      expect(path, isNotNull);
      final doc = File(path!);
      expect(doc.existsSync(), isTrue);
      // macOS loadFileURL only grants read access to the document's own
      // directory, so the images must be siblings.
      expect(doc.parent.path, (await dirFor('email-1')).path);
    });

    test('reuses the same path for identical html', () async {
      final a = await cache.writeDocument(cacheKey: 'e', html: '<p>hi</p>');
      final b = await cache.writeDocument(cacheKey: 'e', html: '<p>hi</p>');
      expect(a, b);
    });

    test('writes a distinct file when the html changes', () async {
      final blocked = await cache.writeDocument(cacheKey: 'e', html: '<a>');
      final allowed = await cache.writeDocument(cacheKey: 'e', html: '<b>');
      expect(blocked, isNot(allowed));
      expect(File(blocked!).existsSync(), isTrue);
      expect(File(allowed!).existsSync(), isTrue);
    });
  });

  group('eviction', () {
    test('evictEmail removes only that email\'s directory', () async {
      await cache.materialize(cacheKey: 'keep', attachments: [_png('<a>', [1])]);
      await cache.materialize(cacheKey: 'drop', attachments: [_png('<b>', [2])]);

      await cache.evictEmail('drop');

      expect((await dirFor('drop')).existsSync(), isFalse);
      expect((await dirFor('keep')).existsSync(), isTrue);
    });

    test('evictEmail is a no-op for an uncached email', () async {
      await expectLater(cache.evictEmail('never-seen'), completes);
    });

    test('clear empties the cache but leaves it usable', () async {
      await cache.materialize(cacheKey: 'a', attachments: [_png('<a>', [1])]);
      await cache.materialize(cacheKey: 'b', attachments: [_png('<b>', [2])]);

      await cache.clear();
      expect((await dirFor('a')).existsSync(), isFalse);
      expect((await dirFor('b')).existsSync(), isFalse);

      final mapping =
          await cache.materialize(cacheKey: 'c', attachments: [_png('<c>', [3])]);
      expect(mapping, isNotNull);
      expect((await dirFor('c')).existsSync(), isTrue);
    });
  });

  group('prune', () {
    test('drops entries older than maxAge and keeps recent ones', () async {
      await cache.materialize(cacheKey: 'old', attachments: [_png('<a>', [1])]);
      await cache.materialize(cacheKey: 'new', attachments: [_png('<b>', [2])]);

      final stale = DateTime.now().subtract(const Duration(days: 45));
      for (final f in (await dirFor('old')).listSync().whereType<File>()) {
        f.setLastModifiedSync(stale);
      }

      await cache.prune(maxAge: const Duration(days: 30));

      expect((await dirFor('old')).existsSync(), isFalse);
      expect((await dirFor('new')).existsSync(), isTrue);
    });

    test('drops an empty directory', () async {
      final orphan = await dirFor('orphan');
      orphan.createSync(recursive: true);

      await cache.prune();

      expect(orphan.existsSync(), isFalse);
    });
  });

  test('degrades to no-ops when no cache directory is available', () async {
    // Simulates a headless binding where getTemporaryDirectory() throws.
    final unusable = InlineAttachmentCache();
    expect(
      await unusable.materialize(
        cacheKey: 'e',
        attachments: [_png('<a>', [1])],
      ),
      isNull,
    );
    expect(await unusable.writeDocument(cacheKey: 'e', html: '<p>'), isNull);
    await expectLater(unusable.evictEmail('e'), completes);
    await expectLater(unusable.clear(), completes);
    await expectLater(unusable.prune(), completes);
  });
}
