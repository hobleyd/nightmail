import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/diagnostics/diagnostic_log.dart';

void main() {
  late Directory dir;
  late DebugPrintCallback originalDebugPrint;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('diagnostic_log_test');
    originalDebugPrint = debugPrint;
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  DiagnosticLog make({
    int maxBytes = DiagnosticLog.defaultMaxBytes,
    Future<Directory> Function()? directory,
  }) =>
      DiagnosticLog(
        windowLabel: 'main',
        directory: directory ?? () async => dir,
        maxBytes: maxBytes,
        now: () => DateTime(2026, 10, 1, 15, 21, 53, 123),
      );

  test('writes each message as a timestamped line naming the window',
      () async {
    final log = make()..open();

    log.record('[NightMail] recipient search error: boom');
    await log.flush();

    expect(
      log.file!.readAsStringSync(),
      '2026-10-01T15:21:53.123 [main] [NightMail] recipient search error: '
      'boom\n',
    );
  });

  test('indents the continuation lines of a multi-line message', () async {
    final log = make()..open();

    log.record('first\nsecond\nthird');
    await log.flush();

    expect(
      log.file!.readAsStringSync(),
      '2026-10-01T15:21:53.123 [main] first\n    second\n    third\n',
    );
  });

  test('keeps what was said before the directory was known', () async {
    final ready = Completer<Directory>();
    final log = make(directory: () => ready.future);

    log.record('said before open');
    log.open();
    log.record('said while opening');
    expect(log.file, isNull);

    ready.complete(dir);
    await log.flush();

    expect(
      log.file!.readAsLinesSync(),
      [
        '2026-10-01T15:21:53.123 [main] said before open',
        '2026-10-01T15:21:53.123 [main] said while opening',
      ],
    );
  });

  test('rotates to .1 before a write that would pass maxBytes', () async {
    // Each line is 32 bytes of prefix plus the message.
    final log = make(maxBytes: 200)..open();

    for (var i = 1; i <= 3; i++) {
      log.record('line $i ${'x' * 60}');
      await log.flush();
    }

    final rotated = log.rotatedFile!.readAsLinesSync();
    expect(rotated.length, 2);
    expect(rotated.first, endsWith('line 1 ${'x' * 60}'));
    expect(rotated.last, endsWith('line 2 ${'x' * 60}'));
    final current = log.file!.readAsLinesSync();
    expect(current.length, 1);
    expect(current.single, endsWith('line 3 ${'x' * 60}'));
  });

  test('a rotation replaces the previous .1 rather than growing it', () async {
    final log = make(maxBytes: 120)..open();

    for (var i = 1; i <= 4; i++) {
      log.record('line $i ${'x' * 60}');
      await log.flush();
    }

    expect(log.rotatedFile!.readAsLinesSync().single, contains(' line 3 '));
    expect(log.file!.readAsLinesSync().single, contains(' line 4 '));
  });

  test('picks up the size of a file left by an earlier run', () async {
    File('${dir.path}/${DiagnosticLog.fileName}')
        .writeAsStringSync('${'y' * 150}\n');
    final log = make(maxBytes: 200)..open();

    log.record('line ${'x' * 60}');
    await log.flush();

    expect(log.rotatedFile!.readAsStringSync(), '${'y' * 150}\n');
    expect(log.file!.readAsLinesSync().single, endsWith('line ${'x' * 60}'));
  });

  test('never throws when the directory cannot be resolved', () async {
    final log = make(directory: () async => throw StateError('no home'));

    log.record('lost');
    log.open();
    await log.flush();
    log.record('also lost');
    await log.flush();

    expect(log.file, isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('attach tees debugPrint, keeping what it did before; detach restores it',
      () async {
    final console = <String?>[];
    void silent(String? message, {int? wrapWidth}) => console.add(message);
    debugPrint = silent;
    final log = make()..open();

    log.attach();
    debugPrint('[Compose] hello');
    await log.flush();
    log.detach();
    debugPrint('[Compose] after detach');
    await log.flush();

    expect(console, ['[Compose] hello', '[Compose] after detach']);
    expect(log.file!.readAsLinesSync().single, endsWith('[Compose] hello'));
    expect(debugPrint, same(silent));
  });

  test('close detaches and leaves the file complete', () async {
    void silent(String? message, {int? wrapWidth}) {}
    debugPrint = silent;
    final log = make()..open();
    log.attach();

    debugPrint('last words');
    await log.close();

    expect(debugPrint, same(silent));
    expect(log.file!.readAsLinesSync().single, endsWith('last words'));
  });
}
