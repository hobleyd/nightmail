import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/task_due.dart';
import '../../domain/entities/task_email_link.dart';
import '../../domain/entities/todo_task.dart';

/// Whether a list row's message has an open follow-up task, and whether that
/// task is past due — what colours the row's flag icon.
enum EmailTaskFlag {
  none,
  flagged,
  overdue;

  /// The more urgent of the two — a thread with one overdue task among
  /// several reads as overdue.
  EmailTaskFlag operator |(EmailTaskFlag other) =>
      index >= other.index ? this : other;

  /// The flag icon's colour: [fallback] when there is no task, the accent
  /// while it is still before its due date, the shared attention colour once
  /// it is past it (same rule as the tasks pane's red due line).
  Color color(Color fallback) => switch (this) {
        EmailTaskFlag.none => fallback,
        EmailTaskFlag.flagged => AppColors.accent,
        EmailTaskFlag.overdue => AppColors.notification,
      };

  /// The flag for the message [emailId] from [byEmailId]
  /// (see [emailTaskFlags]).
  static EmailTaskFlag of(String emailId, Map<String, EmailTaskFlag> byEmailId) =>
      byEmailId[emailId] ?? EmailTaskFlag.none;

  /// The flag for a thread: the most urgent of its messages'.
  static EmailTaskFlag ofAll(
    Iterable<String> emailIds,
    Map<String, EmailTaskFlag> byEmailId,
  ) =>
      emailIds.fold(
          EmailTaskFlag.none, (acc, id) => acc | of(id, byEmailId));
}

/// Message id to [EmailTaskFlag], from the open tasks whose notes carry a
/// [TaskEmailLink] marker — which every task the flag button creates does.
///
/// [tasks] is what `TasksBloc` holds: the open tasks of the selected list,
/// which is the list the flag button files into. A completed task drops out,
/// so the flag goes back to plain.
Map<String, EmailTaskFlag> emailTaskFlags(
  Iterable<TodoTask> tasks, {
  DateTime? now,
}) {
  final flags = <String, EmailTaskFlag>{};
  for (final task in tasks) {
    if (task.isCompleted) continue;
    final emailId = TaskEmailLink.emailIdFrom(task.body);
    if (emailId == null) continue;
    final due = task.dueDateTime;
    final flag = due != null && isTaskOverdue(due, now: now)
        ? EmailTaskFlag.overdue
        : EmailTaskFlag.flagged;
    flags[emailId] = flag | (flags[emailId] ?? EmailTaskFlag.none);
  }
  return flags;
}
