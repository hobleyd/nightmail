import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/theme/app_colors.dart';
import 'package:nightmail/domain/entities/task_email_link.dart';
import 'package:nightmail/domain/entities/todo_task.dart';
import 'package:nightmail/presentation/widgets/email_task_flag.dart';

void main() {
  final now = DateTime(2026, 10, 15, 12);

  TodoTask task(
    String id, {
    String? emailId,
    DateTime? due,
    TodoTaskStatus status = TodoTaskStatus.notStarted,
  }) =>
      TodoTask(
        id: id,
        listId: 'list',
        title: id,
        status: status,
        dueDateTime: due,
        body: emailId == null
            ? 'no link'
            : 'From: Someone\n\n${TaskEmailLink.marker(emailId)}',
      );

  group('emailTaskFlags', () {
    test('a task due today or later is flagged, not overdue', () {
      final flags = emailTaskFlags([
        task('a', emailId: 'e1', due: DateTime.utc(2026, 10, 15)),
        task('b', emailId: 'e2', due: DateTime.utc(2026, 10, 20)),
        task('c', emailId: 'e3'),
      ], now: now);
      expect(flags, {
        'e1': EmailTaskFlag.flagged,
        'e2': EmailTaskFlag.flagged,
        'e3': EmailTaskFlag.flagged,
      });
    });

    test('a task due before today is overdue', () {
      final flags = emailTaskFlags([
        task('a', emailId: 'e1', due: DateTime.utc(2026, 10, 14)),
      ], now: now);
      expect(flags, {'e1': EmailTaskFlag.overdue});
    });

    test('completed and unlinked tasks are ignored', () {
      final flags = emailTaskFlags([
        task('a',
            emailId: 'e1',
            due: DateTime.utc(2026, 10, 1),
            status: TodoTaskStatus.completed),
        task('b'),
      ], now: now);
      expect(flags, isEmpty);
    });

    test('two tasks on one message keep the more urgent', () {
      final flags = emailTaskFlags([
        task('a', emailId: 'e1', due: DateTime.utc(2026, 10, 1)),
        task('b', emailId: 'e1', due: DateTime.utc(2026, 10, 30)),
      ], now: now);
      expect(flags, {'e1': EmailTaskFlag.overdue});
    });
  });

  test('a thread takes the most urgent of its messages', () {
    const flags = {
      'e1': EmailTaskFlag.flagged,
      'e2': EmailTaskFlag.overdue,
    };
    expect(EmailTaskFlag.ofAll(['e0', 'e1'], flags), EmailTaskFlag.flagged);
    expect(EmailTaskFlag.ofAll(['e1', 'e2'], flags), EmailTaskFlag.overdue);
    expect(EmailTaskFlag.ofAll(['e0'], flags), EmailTaskFlag.none);
  });

  test('colours: muted, accent, attention', () {
    const muted = Color(0xFF000000);
    expect(EmailTaskFlag.none.color(muted), muted);
    expect(EmailTaskFlag.flagged.color(muted), AppColors.accent);
    expect(EmailTaskFlag.overdue.color(muted), AppColors.notification);
  });
}
