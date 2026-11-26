// The meeting-reminders window measures MeetingReminderList at its natural
// height and fits itself to that, so the list must lay out cleanly unbounded —
// at any row count and text size — and grow with what it shows rather than
// clip it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/infrastructure/notifications/meeting_reminder_board.dart';
import 'package:nightmail/presentation/pages/meeting_reminders_window.dart';
import 'package:nightmail/presentation/widgets/meeting_reminder_list.dart';

void main() {
  final start = DateTime.utc(2026, 10, 29, 10);
  final contentKey = GlobalKey();

  List<MeetingReminderRow> rows(int n) => [
        for (var i = 0; i < n; i++)
          MeetingReminderRow(
            accountId: 'a',
            eventId: 'e$i',
            title: 'A meeting with a long enough title to need eliding $i',
            start: start.add(Duration(minutes: i)),
            end: start.add(const Duration(minutes: 30)),
            minutesUntilStart: 10,
            location: 'Room $i',
          ),
      ];

  Future<double> pumpList(WidgetTester tester, int n, double textScale) async {
    tester.view.physicalSize = const Size(MeetingRemindersWindowApp.width, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: KeyedSubtree(
              key: contentKey,
              child: MeetingReminderList(
                rows: rows(n),
                onDismiss: (_) {},
                onDismissAll: () {},
                onJoin: (_) {},
              ),
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    return tester.getSize(find.byKey(contentKey)).height;
  }

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('lays out cleanly at text scale $scale', (tester) async {
      final heights = [
        for (var n = 1; n <= 5; n++) await pumpList(tester, n, scale),
      ];
      for (var i = 1; i < heights.length; i++) {
        expect(heights[i], greaterThan(heights[i - 1]),
            reason: 'each row adds to the height the window fits to');
      }
    });
  }

  testWidgets('larger text asks for a taller window', (tester) async {
    final normal = await pumpList(tester, 2, 1);
    final large = await pumpList(tester, 2, 2);
    expect(large, greaterThan(normal));
  });

  testWidgets('Join shows only on a starting-now row with a link',
      (tester) async {
    MeetingReminderRow row(String id, int minutes, String? url) =>
        MeetingReminderRow(
          accountId: 'a',
          eventId: id,
          title: 'Meeting $id',
          start: start,
          end: start.add(const Duration(minutes: 30)),
          minutesUntilStart: minutes,
          onlineMeetingUrl: url,
        );
    const url = 'https://meet.google.com/abc-defg-hij';
    MeetingReminderRow? joined;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MeetingReminderList(
            rows: [row('soon', 5, url), row('now', 0, url), row('room', 0, null)],
            onDismiss: (_) {},
            onDismissAll: () {},
            onJoin: (r) => joined = r,
          ),
        ),
      ),
    ));
    expect(find.text('Join'), findsOneWidget);
    await tester.tap(find.text('Join'));
    expect(joined?.eventId, 'now');
  });
}
