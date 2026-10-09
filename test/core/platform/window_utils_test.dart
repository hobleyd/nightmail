import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/platform/window_utils.dart';

// ---------------------------------------------------------------------------
// showOrCreateSubWindow — one Calendar / Tasks / Commitments window at a time.
//
// The main window keeps no list of what it has opened (a sub-window closes on
// its own and takes its isolate with it), so the plugin's registry is asked,
// and the type is read back out of the arguments each window was created
// with. What is pinned: an open window of the type is fronted rather than
// duplicated, anything else in the registry — the main window's empty
// arguments, another kind of window — is passed over, and a window that
// vanishes between lookup and show is replaced rather than left for dead.
//
// createSubWindow — a double-click opens one window.
//
// Reply, Forward, New Email, an inline image: each is a plain button that
// fires once per click, and macOS hands Flutter a double-click as two clicks.
// Pinned: the same window asked for again within the OS's double-click
// interval of the first opening — or while the first is still being created —
// is answered with the first; after the interval, or for a different window,
// a second one opens; a create that failed is not remembered.
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowChannel = MethodChannel('mixin.one/desktop_multi_window');
  const utilsChannel = MethodChannel('au.com.sharpblue.nightmail/window_utils');

  /// What `getAllWindows` answers, as the plugin encodes it.
  var registry = <Map<String, String>>[];
  final shown = <String>[];
  final created = <String>[];
  var showFails = false;

  void mock(MethodChannel channel, Future<Object?>? Function(MethodCall)? h) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, h);
  }

  setUp(() {
    registry = [];
    shown.clear();
    created.clear();
    showFails = false;
    mock(windowChannel, (call) async {
      switch (call.method) {
        case 'getAllWindows':
          return registry;
        case 'window_show':
          if (showFails) {
            throw PlatformException(code: '-1', message: 'no such window');
          }
          shown.add((call.arguments as Map)['windowId'] as String);
          return null;
        case 'createWindow':
          created.add((call.arguments as Map)['arguments'] as String);
          return '9';
      }
      return null;
    });
    mock(utilsChannel, (call) async => null);
  });

  tearDown(() {
    mock(windowChannel, null);
    mock(utilsChannel, null);
  });

  Map<String, String> window(String id, String arguments) =>
      {'windowId': id, 'windowArgument': arguments};

  test('reads the type back out of the arguments a window was created with',
      () {
    expect(subWindowTypeOf(jsonEncode({'type': 'calendar', 'x': 1})),
        'calendar');
    expect(subWindowTypeOf(''), isNull, reason: 'the main window');
    expect(subWindowTypeOf('not json'), isNull);
    expect(subWindowTypeOf(jsonEncode([1, 2])), isNull);
    expect(subWindowTypeOf(jsonEncode({'mode': 'reply'})), isNull,
        reason: 'a compose window has no type');
  });

  test('fronts the open window of the type instead of opening another',
      () async {
    registry = [
      window('0', ''),
      window('3', jsonEncode({'type': 'tasks'})),
      window('5', jsonEncode({'type': 'calendar', '_screenInfo': {}})),
    ];

    final controller = await showOrCreateSubWindow('calendar');

    expect(controller.windowId, '5');
    expect(shown, ['5']);
    expect(created, isEmpty);
  });

  test('opens a window when none of the type is open', () async {
    registry = [
      window('0', ''),
      window('3', jsonEncode({'type': 'tasks'})),
      window('4', jsonEncode({'mode': 'newEmail'})),
    ];

    final controller = await showOrCreateSubWindow('commitments');

    expect(controller.windowId, '9');
    expect(shown, isEmpty);
    expect(created, hasLength(1));
    expect(jsonDecode(created.single), containsPair('type', 'commitments'));
  });

  test('a window that closed between the lookup and the show is replaced',
      () async {
    registry = [window('5', jsonEncode({'type': 'calendar'}))];
    showFails = true;

    final controller = await showOrCreateSubWindow('calendar');

    expect(controller.windowId, '9');
    expect(created, hasLength(1));
  });

  test('an unanswered registry is treated as empty', () async {
    mock(windowChannel, (call) async {
      if (call.method == 'getAllWindows') {
        throw PlatformException(code: 'unimplemented');
      }
      created.add((call.arguments as Map)['arguments'] as String);
      return '9';
    });

    final controller = await showOrCreateSubWindow('tasks');

    expect(controller.windowId, '9');
    expect(created, hasLength(1));
  });

  group('platformDoubleClickInterval', () {
    setUp(resetPlatformDoubleClickInterval);
    tearDown(resetPlatformDoubleClickInterval);

    test("is the OS's figure where the platform reports one", () async {
      mock(utilsChannel, (call) async =>
          call.method == 'getDoubleClickIntervalMs' ? 500.0 : null);

      expect(await platformDoubleClickInterval(),
          const Duration(milliseconds: 500));
    });

    test("falls back to Flutter's where it does not", () async {
      mock(utilsChannel, (call) async => null);
      expect(await platformDoubleClickInterval(),
          const Duration(milliseconds: 300));

      mock(utilsChannel, (call) async {
        throw MissingPluginException();
      });
      resetPlatformDoubleClickInterval();
      expect(await platformDoubleClickInterval(),
          const Duration(milliseconds: 300));
    });
  });

  group('createSubWindow treats a double-click as one click', () {
    var now = DateTime(2026, 10, 7, 7, 57, 50);

    setUp(() {
      resetPlatformDoubleClickInterval();
      resetLastSubWindowCreate();
      now = DateTime(2026, 10, 7, 7, 57, 50);
      subWindowClock = () => now;
      mock(utilsChannel, (call) async =>
          call.method == 'getDoubleClickIntervalMs' ? 500.0 : null);
    });

    tearDown(() {
      subWindowClock = DateTime.now;
      resetLastSubWindowCreate();
      resetPlatformDoubleClickInterval();
    });

    WindowConfiguration reply({String mode = 'reply'}) => WindowConfiguration(
          arguments: jsonEncode({
            'mode': mode,
            'originalEmail': {'id': 'm1'},
          }),
        );

    test('a repeat while the first is still being created is answered with it',
        () async {
      final gate = Completer<String>();
      mock(windowChannel, (call) async {
        created.add((call.arguments as Map)['arguments'] as String);
        return gate.future;
      });

      final first = createSubWindow(reply());
      final second = createSubWindow(reply());
      // Let both requests reach the channel before the native side answers.
      await Future<void>.delayed(Duration.zero);
      gate.complete('9');
      final controllers = await Future.wait([first, second]);

      expect(created, hasLength(1));
      expect(controllers.map((c) => c.windowId), ['9', '9']);
    });

    test('a repeat inside the double-click interval of the first opening is '
        'the same click', () async {
      final first = await createSubWindow(reply());
      now = now.add(const Duration(milliseconds: 400));

      final second = await createSubWindow(reply());

      expect(created, hasLength(1));
      expect(second.windowId, first.windowId);
      expect(shown, isEmpty, reason: 'the window is still coming up');
    });

    test('a request after the interval is a second window', () async {
      await createSubWindow(reply());
      now = now.add(const Duration(milliseconds: 501));

      await createSubWindow(reply());

      expect(created, hasLength(2));
    });

    test('a different window inside the interval is opened', () async {
      await createSubWindow(reply());
      now = now.add(const Duration(milliseconds: 100));

      await createSubWindow(reply(mode: 'replyAll'));

      expect(created, hasLength(2));
      expect(jsonDecode(created.last), containsPair('mode', 'replyAll'));
    });

    test('a create that failed is not remembered', () async {
      var fails = true;
      mock(windowChannel, (call) async {
        if (fails) throw PlatformException(code: '-1', message: 'no engine');
        created.add((call.arguments as Map)['arguments'] as String);
        return '9';
      });

      await expectLater(
          createSubWindow(reply()), throwsA(isA<PlatformException>()));
      fails = false;
      await createSubWindow(reply());

      expect(created, hasLength(1));
    });
  });
}
