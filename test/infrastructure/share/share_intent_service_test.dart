import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/infrastructure/share/share_intent_service.dart';
import 'package:nightmail/presentation/pages/compose_window.dart';

// Android's MainActivity and the iOS Share Extension both hand Dart the same
// map; these cover reading it and turning it into a compose draft.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedContent.fromMap', () {
    test('reads subject, text and files', () {
      final content = SharedContent.fromMap({
        'subject': ' A page title ',
        'text': 'https://example.com/article\n',
        'files': [
          {'path': '/cache/shared/1/0/report.pdf', 'name': 'report.pdf',
           'mimeType': 'application/pdf'},
          {'path': '/cache/shared/1/1/IMG_0001.HEIC'},
        ],
      });

      expect(content.subject, 'A page title');
      expect(content.text, 'https://example.com/article');
      expect(content.files.map((f) => f.name),
          ['report.pdf', 'IMG_0001.HEIC']);
      expect(content.files.first.mimeType, 'application/pdf');
      expect(content.files.last.mimeType, isNull);
    });

    test('null text and subject read as empty, and bad entries are skipped',
        () {
      final content = SharedContent.fromMap({
        'subject': null,
        'text': null,
        'files': ['not a map', {'path': ''}, {'name': 'no-path.txt'}],
      });

      expect(content.isEmpty, isTrue);
    });

    test('anything but a map is empty', () {
      expect(SharedContent.fromMap('nonsense').isEmpty, isTrue);
      expect(SharedContent.fromMap(null).isEmpty, isTrue);
    });
  });

  test('a share becomes a plain-text draft with its subject', () {
    final draft = ComposeWindowApp.sharedDraft(
      const SharedContent(subject: 'Look at this', text: 'https://a.example'),
    );

    expect(draft.subject, 'Look at this');
    expect(draft.body, 'https://a.example');
    expect(draft.bodyType, EmailBodyType.text);
    expect(draft.toRecipients, isEmpty);
  });

  group('ShareIntentService', () {
    const channel = MethodChannel('au.com.sharpblue.nightmail/share_intent');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('takePendingShare returns null for nothing pending or an empty share',
        () async {
      Object? reply;
      messenger.setMockMethodCallHandler(channel, (_) async => reply);

      expect(await ShareIntentService().takePendingShare(), isNull);
      reply = {'subject': '', 'text': '', 'files': []};
      expect(await ShareIntentService().takePendingShare(), isNull);
    });

    test('readAttachments reads each copy and deletes it, skipping a missing one',
        () async {
      final dir = await Directory.systemTemp.createTemp('share_test');
      addTearDown(() => dir.delete(recursive: true));
      final present = File('${dir.path}/notes.txt')
        ..writeAsStringSync('hello');

      final attachments = await ShareIntentService().readAttachments(
        SharedContent(files: [
          SharedFile(path: present.path, name: 'notes.txt'),
          SharedFile(path: '${dir.path}/gone.pdf', name: 'gone.pdf'),
        ]),
      );

      expect(attachments.map((a) => a.name), ['notes.txt']);
      expect(attachments.single.mimeType, 'text/plain');
      expect(String.fromCharCodes(attachments.single.bytes), 'hello');
      expect(present.existsSync(), isFalse);
    });
  });
}
