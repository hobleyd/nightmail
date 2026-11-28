import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/folder_listing.dart';

final _day = DateTime(2026, 6, 1);

Email _row(String id, int hoursAgo,
        {String? conversationId, String? parentFolderId = 'inbox'}) =>
    Email(
      id: id,
      subject: id,
      from: const EmailAddress(address: 'a@b.com'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: _day.subtract(Duration(hours: hoursAgo)),
      importance: EmailImportance.normal,
      conversationId: conversationId,
      parentFolderId: parentFolderId,
    );

void main() {
  group('listingWindowStart', () {
    test('dates a thread by its newest row, so a Sent reply newer than the '
        'listed message narrows the window', () {
      final page = [
        for (var i = 0; i < 24; i++) _row('m$i', i),
        _row('listed', 30, conversationId: 'c'),
        _row('reply', 2, conversationId: 'c', parentFolderId: 'sent'),
      ];

      expect(listingWindowStart(page, folderId: 'inbox', pageSize: 25),
          _day.subtract(const Duration(hours: 23)));
    });

    // The dangerous direction: a page taken as short says the folder ends
    // there, and every cached row older than it is dropped.
    test('the server\'s listed count overrides the rows: a full Gmail page '
        'whose threads are partly in Trash is still full', () {
      final page = [for (var i = 0; i < 20; i++) _row('m$i', i)];

      expect(
          listingWindowStart(page,
              folderId: 'inbox', pageSize: 25, listedCount: 25),
          _day.subtract(const Duration(hours: 19)));
      expect(
          listingWindowStart(page,
              folderId: 'inbox', pageSize: 25, listedCount: 20),
          isNull);
    });

    test('without a listed count, a page short of both messages and threads '
        'reaches the end', () {
      expect(
          listingWindowStart([_row('a', 1)], folderId: 'inbox', pageSize: 25),
          isNull);
    });
  });

  test('lastThreadOf is the oldest thread, ties broken by key', () {
    final cursor = lastThreadOf([
      _row('a', 1),
      _row('b', 5),
      _row('c', 5),
    ]);
    expect(cursor,
        CacheCursor(threadDate: _day.subtract(const Duration(hours: 5)),
            threadKey: 'b'));
  });

  test('FolderCoverage covers from its edge, or everything when complete', () {
    final edge = _day;
    expect(FolderCoverage(coveredFrom: edge).covers(edge), isTrue);
    expect(
        FolderCoverage(coveredFrom: edge)
            .covers(edge.subtract(const Duration(seconds: 1))),
        isFalse);
    expect(const FolderCoverage(complete: true).covers(DateTime(1990)), isTrue);
  });
}
