import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/platform/window_utils.dart';
import 'package:nightmail/presentation/blocs/tasks/overdue_tasks_cubit.dart';
import 'package:nightmail/presentation/widgets/view_shortcut_buttons.dart';

import 'folder_panel_test.mocks.dart';

// ---------------------------------------------------------------------------
// ViewShortcutButtons — one click toggles the pane, two open the window.
//
// Regression these exist for: the buttons were an IconButton inside a
// GestureDetector.onDoubleTap, whose recognizer gives up after 300 ms where
// macOS allows 500 by default. A double-click the OS accepted therefore
// reached the app as two single taps: the pane toggled twice and no window
// opened — or, when one half made it through, the pane toggled *and* a window
// opened. And every double-click opened a new window, whether or not one was
// already on screen.
//
// The tests run on the desktop host, so the desktop paths are the ones under
// test. The OS interval is mocked at 500 ms and the clicks are spaced at 400:
// inside the OS's window, outside Flutter's.
// ---------------------------------------------------------------------------

void main() {
  const windowChannel = MethodChannel('mixin.one/desktop_multi_window');
  const utilsChannel = MethodChannel('au.com.sharpblue.nightmail/window_utils');
  const osInterval = Duration(milliseconds: 500);
  const slowGap = Duration(milliseconds: 400);

  var registry = <Map<String, String>>[];
  final shown = <String>[];
  final created = <String>[];
  var taps = <String>[];

  void mock(MethodChannel channel, Future<Object?>? Function(MethodCall)? h) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, h);
  }

  setUp(() {
    registry = [];
    shown.clear();
    created.clear();
    taps = [];
    resetPlatformDoubleClickInterval();
    mock(windowChannel, (call) async {
      switch (call.method) {
        case 'getAllWindows':
          return registry;
        case 'window_show':
          shown.add((call.arguments as Map)['windowId'] as String);
          return null;
        case 'createWindow':
          created.add((call.arguments as Map)['arguments'] as String);
          return '9';
      }
      return null;
    });
    mock(utilsChannel, (call) async {
      if (call.method == 'getDoubleClickIntervalMs') {
        return osInterval.inMilliseconds.toDouble();
      }
      return null;
    });
  });

  tearDown(() {
    mock(windowChannel, null);
    mock(utilsChannel, null);
    resetPlatformDoubleClickInterval();
  });

  Future<void> pump(WidgetTester tester) async {
    final overdue = MockOverdueTasksCubit();
    when(overdue.stream).thenAnswer((_) => const Stream.empty());
    when(overdue.state).thenReturn(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<OverdueTasksCubit>.value(
            value: overdue,
            child: ViewShortcutButtons(
              onCalendarTapped: () => taps.add('calendar'),
              onTasksTapped: () => taps.add('tasks'),
              onAiTapped: () => taps.add('ai'),
              onCommitmentsTapped: () => taps.add('commitments'),
            ),
          ),
        ),
      ),
    );
    // Lets the interval answer land.
    await tester.pump();
  }

  Finder button(String tooltip) => find.byTooltip(tooltip);

  testWidgets('one click toggles the pane once the OS interval has passed',
      (tester) async {
    await pump(tester);

    await tester.tap(button('Calendar'));
    await tester.pump(slowGap);
    expect(taps, isEmpty, reason: 'a second click may still be coming');

    await tester.pump(osInterval - slowGap);
    expect(taps, ['calendar']);
    expect(created, isEmpty);
    expect(shown, isEmpty);
  });

  testWidgets('a double-click at the OS\'s pace opens the window, not the pane',
      (tester) async {
    await pump(tester);

    await tester.tap(button('Commitments'));
    await tester.pump(slowGap);
    await tester.tap(button('Commitments'));
    await tester.pump(osInterval * 2);

    expect(taps, isEmpty);
    expect(created, hasLength(1));
    expect(jsonDecode(created.single), containsPair('type', 'commitments'));
  });

  testWidgets('a double-click fronts the window already open', (tester) async {
    registry = [
      {'windowId': '0', 'windowArgument': ''},
      {
        'windowId': '5',
        'windowArgument': jsonEncode({'type': 'tasks', '_screenInfo': {}}),
      },
    ];
    await pump(tester);

    await tester.tap(button('Tasks'));
    await tester.pump(slowGap);
    await tester.tap(button('Tasks'));
    await tester.pump(osInterval * 2);

    expect(taps, isEmpty);
    expect(shown, ['5']);
    expect(created, isEmpty);
  });

  testWidgets('clicks spaced wider than the interval are two toggles',
      (tester) async {
    await pump(tester);

    await tester.tap(button('Calendar'));
    await tester.pump(osInterval + const Duration(milliseconds: 50));
    await tester.tap(button('Calendar'));
    await tester.pump(osInterval + const Duration(milliseconds: 50));

    expect(taps, ['calendar', 'calendar']);
    expect(created, isEmpty);
  });

  testWidgets('AI has no window: it toggles at once, and a double-click once',
      (tester) async {
    await pump(tester);

    await tester.tap(button('AI'));
    expect(taps, ['ai'], reason: 'nothing to wait for');

    await tester.pump(slowGap);
    await tester.tap(button('AI'));
    await tester.pump(osInterval * 2);

    expect(taps, ['ai']);
    expect(created, isEmpty);
  });

  testWidgets('the toggle still fires after the row was rebuilt mid-wait',
      (tester) async {
    await pump(tester);

    await tester.tap(button('Calendar'));
    await tester.pump(slowGap);
    // A rebuild hands the button a fresh callback; the pending click must
    // call the one current when it fires.
    taps = [];
    await pump(tester);
    await tester.pump(osInterval);

    expect(taps, ['calendar']);
  });
}
