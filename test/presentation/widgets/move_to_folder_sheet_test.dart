import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/presentation/widgets/move_to_folder_sheet.dart';

EmailFolder _folder(String id, String name, {String? parent, bool hidden = false}) =>
    EmailFolder(
      id: id,
      displayName: name,
      totalItemCount: 0,
      unreadItemCount: 0,
      parentFolderId: parent,
      isHidden: hidden,
    );

void main() {
  final folders = [
    _folder('projects', 'Projects'),
    _folder('acme', 'Acme', parent: 'projects'),
    _folder('inbox', 'Inbox'),
    _folder('archive', 'Archive'),
    _folder('CATEGORY_PERSONAL', 'Personal'),
    _folder('secret', 'Hidden', hidden: true),
  ];

  Future<Future<EmailFolder?>> open(WidgetTester tester) async {
    late Future<EmailFolder?> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => result = showMoveToFolderSheet(
            context,
            folders: folders,
            currentFolderId: 'inbox',
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('lists the tree in folder-panel order, without categories or '
      'hidden folders', (tester) async {
    await open(tester);

    final titles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title as Text).data)
        .toList();
    expect(titles, ['Inbox', 'Archive', 'Projects', 'Acme']);
  });

  testWidgets('the current folder cannot be chosen', (tester) async {
    await open(tester);

    final inbox = tester.widget<ListTile>(
        find.ancestor(of: find.text('Inbox'), matching: find.byType(ListTile)));
    expect(inbox.enabled, isFalse);
  });

  testWidgets('answers the folder tapped', (tester) async {
    final result = await open(tester);

    await tester.tap(find.text('Acme'));
    await tester.pumpAndSettle();

    expect((await result)?.id, 'acme');
  });
}
