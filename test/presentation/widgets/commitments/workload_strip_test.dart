import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/workload_forecast.dart';
import 'package:nightmail/presentation/widgets/commitments/rebalance_dialog.dart';
import 'package:nightmail/presentation/widgets/commitments/workload_strip.dart';

/// The week-ahead strip in both layouts and the rebalance dialog, over a
/// hand-built forecast so nothing depends on the wall clock.
void main() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  // Five consecutive days from today; the strip only needs *days*, not a
  // real working-day horizon.
  final days = [for (var i = 0; i < 5; i++) today.add(Duration(days: i))];

  Commitment commitment(String id, {int urgency = 1, DateTime? start, DateTime? end}) =>
      Commitment(
        id: 'iOwe:$id',
        accountId: 'acc',
        emailId: id,
        kind: CommitmentKind.iOwe,
        status: CommitmentStatus.open,
        counterpart: EmailAddress(address: '$id@y.com', name: id),
        subject: 'Subject $id',
        snippet: '',
        due: CommitmentDue.thisWeek,
        urgency: urgency,
        confidence: 0.9,
        emailDate: now,
        detectedAt: now,
        scheduledEventId: start == null ? null : 'ev-$id',
        scheduledStart: start,
        scheduledEnd: end,
      );

  DayForecast day(
    DateTime d, {
    int meetings = 0,
    int blocked = 0,
    List<Commitment> landing = const [],
    int tasks = 0,
  }) =>
      DayForecast(
        day: d,
        workingMinutes: 480,
        meetingMinutes: meetings,
        blockedMinutes: blocked,
        landing: landing,
        tasksDue: tasks,
        minutesPerCommitment: 60,
        minutesPerTask: 30,
      );

  final sarah = commitment('Sarah', urgency: 0);
  final james = commitment('James', urgency: 2);
  // Day 3 is overloaded: 6.5 h of meetings leave 1.5 h, three commitments
  // want 3 h.
  final overloaded = day(days[3], meetings: 390, landing: [sarah, james, commitment('Peter')]);
  final plan = RebalancePlan(
    day: overloaded,
    moves: [
      ScheduleMove(
        commitment: sarah,
        from: null,
        toStart: days[2].add(const Duration(hours: 9)),
        toEnd: days[2].add(const Duration(hours: 10)),
      ),
      ScheduleMove(
        commitment: james,
        from: null,
        toStart: days[2].add(const Duration(hours: 10)),
        toEnd: days[2].add(const Duration(hours: 11)),
      ),
    ],
    relievedMinutes: 120,
  );
  final slot = OpenSlot(
    start: today.add(const Duration(hours: 14)),
    end: today.add(const Duration(hours: 15)),
    suggestion: james,
    freed: true,
  );
  final forecast = WorkloadForecast(
    days: [
      day(days[0], meetings: 120),
      day(days[1], meetings: 60, blocked: 60),
      day(days[2]),
      overloaded,
      day(days[4], meetings: 420, landing: [commitment('Ann')]), // tight: 1 h left, 1 h wanted → overloaded? 60 > 60 no → tight
    ],
    plans: [plan],
    openSlots: [slot],
    computedAt: now,
  );

  Future<void> pump(
    WidgetTester tester, {
    required bool wide,
    required ValueChanged<RebalancePlan> onRebalance,
    required ValueChanged<OpenSlot> onFillSlot,
  }) async {
    if (wide) {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: wide
              ? Align(
                  alignment: Alignment.topCenter,
                  child: WorkloadStrip(
                    forecast: forecast,
                    wide: true,
                    onRebalance: onRebalance,
                    onFillSlot: onFillSlot,
                  ),
                )
              : SizedBox(
                  width: 420,
                  child: WorkloadStrip(
                    forecast: forecast,
                    wide: false,
                    onRebalance: onRebalance,
                    onFillSlot: onFillSlot,
                  ),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('compact strip', () {
    testWidgets('warns about the overloaded day and offers the freed slot',
        (tester) async {
      RebalancePlan? rebalanced;
      OpenSlot? filled;
      await pump(
        tester,
        wide: false,
        onRebalance: (p) => rebalanced = p,
        onFillSlot: (s) => filled = s,
      );

      expect(find.text('WEEK AHEAD'), findsOneWidget);
      expect(find.textContaining('is overloaded: 3 h to do against 1.5 h free.'), findsOneWidget);
      expect(find.textContaining('a meeting just dropped out'), findsOneWidget);
      expect(find.textContaining('Use it for Subject James · James'), findsOneWidget);

      await tester.tap(find.text('Rebalance'));
      expect(rebalanced, same(plan));
      await tester.tap(find.text('Schedule'));
      expect(filled, same(slot));
      expect(tester.takeException(), isNull);
    });
  });

  group('wide strip', () {
    testWidgets('shows a card per day with its state, and the open-slot callout',
        (tester) async {
      RebalancePlan? rebalanced;
      await pump(
        tester,
        wide: true,
        onRebalance: (p) => rebalanced = p,
        onFillSlot: (_) {},
      );

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Tomorrow'), findsOneWidget);
      expect(find.text('Overloaded'), findsOneWidget);
      expect(find.text('Tight'), findsOneWidget);
      expect(find.text('Over by 1.5 h'), findsOneWidget);
      expect(find.textContaining('6.5 h meetings'), findsOneWidget);
      expect(find.text('Just freed up'), findsOneWidget);
      expect(find.textContaining('1 h at '), findsOneWidget);

      await tester.tap(find.text('Rebalance'));
      expect(rebalanced, same(plan));
      expect(tester.takeException(), isNull);
    });
  });

  group('rebalance dialog', () {
    testWidgets('lists the moves, lets one be dropped, and applies the rest',
        (tester) async {
      List<ScheduleMove>? applied;
      int? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await RebalanceDialog.show(
                    context,
                    plan: plan,
                    onApply: (moves) async {
                      applied = moves;
                      return moves.length;
                    },
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Lighten '), findsOneWidget);
      expect(find.text('Subject Sarah · Sarah'), findsOneWidget);
      expect(find.text('Subject James · James'), findsOneWidget);
      expect(find.textContaining('New block ·'), findsNWidgets(2));
      // Both moves relieve 2 h; the day is 1.5 h over, so that resolves it.
      expect(find.textContaining('brings the day within capacity'), findsOneWidget);
      expect(find.text('Apply 2 moves'), findsOneWidget);

      // Drop James's move: 1 h relieved leaves the day 0.5 h over.
      await tester.tap(find.text('Subject James · James'));
      await tester.pumpAndSettle();
      expect(find.textContaining('still over by 0.5 h'), findsOneWidget);
      expect(find.text('Apply 1 move'), findsOneWidget);

      await tester.tap(find.text('Apply 1 move'));
      await tester.pumpAndSettle();

      expect(applied?.map((m) => m.commitment.emailId), ['Sarah']);
      expect(result, 1);
      expect(find.textContaining('Lighten '), findsNothing);
    });
  });
}
