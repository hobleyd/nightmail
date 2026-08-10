// The one rule for "is this task overdue", shared by the tasks pane's red due
// line and the folder panel's Tasks badge. The case worth cover is the
// date-only due date: both providers store it as midnight UTC, so reading the
// day off the local side makes every dated task look a day early in a
// UTC-behind timezone.

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/task_due.dart';

void main() {
  group('taskDueDay', () {
    test('reads a date-only due date off the UTC side', () {
      final day = taskDueDay(DateTime.utc(2026, 8, 11));
      expect(day, DateTime(2026, 8, 11));
    });

    test('reads a due date carrying a time of day as a local moment', () {
      final day = taskDueDay(DateTime(2026, 8, 11, 16, 30));
      expect(day, DateTime(2026, 8, 11));
    });
  });

  group('isTaskOverdue', () {
    final now = DateTime(2026, 8, 11, 9);

    test('a task due today is not overdue — it still has the day to run', () {
      expect(isTaskOverdue(DateTime.utc(2026, 8, 11), now: now), isFalse);
    });

    test('a task due yesterday is overdue', () {
      expect(isTaskOverdue(DateTime.utc(2026, 8, 10), now: now), isTrue);
    });

    test('a task due tomorrow is not overdue', () {
      expect(isTaskOverdue(DateTime.utc(2026, 8, 12), now: now), isFalse);
    });

    test('an earlier time on today is not overdue', () {
      expect(isTaskOverdue(DateTime(2026, 8, 11, 8), now: now), isFalse);
    });
  });
}
