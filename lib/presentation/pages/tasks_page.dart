import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/task_email_link.dart';
import '../../domain/entities/todo_task.dart';
import '../../domain/entities/todo_task_list.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/tasks/tasks_bloc.dart';
import '../blocs/tasks/tasks_event.dart';
import '../blocs/tasks/tasks_state.dart';
import '../widgets/flag_icon_button.dart';

class TasksDayPanel extends StatelessWidget {
  const TasksDayPanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return BlocListener<TasksBloc, TasksState>(
      listenWhen: (prev, curr) =>
          curr is TasksLoaded &&
          curr.pendingEmailAttachmentBytes != null &&
          (prev is! TasksLoaded ||
              prev.pendingEmailAttachmentBytes !=
                  curr.pendingEmailAttachmentBytes),
      listener: (context, state) {
        if (state is! TasksLoaded) return;
        final bytes = state.pendingEmailAttachmentBytes;
        if (bytes == null) return;
        context.read<EmailDetailBloc>().add(
              EmailDetailLoadedFromEml(bytes: bytes),
            );
        context.read<TasksBloc>().add(const TaskAttachmentHandled());
      },
      child: ColoredBox(
        color: c.surfacePanel,
        child: Column(
          children: [
            _Header(onClose: onClose),
            Divider(height: 1, color: c.separatorStrong),
            Expanded(
              child: BlocBuilder<TasksBloc, TasksState>(
                builder: (context, state) {
                  return switch (state) {
                    TasksInitial() => const _EmptyPlaceholder(),
                    TasksLoading() => Center(
                        child: CircularProgressIndicator(
                          color: AppColors.accent,
                          strokeWidth: 2,
                        ),
                      ),
                    TasksLoaded(
                      :final lists,
                      :final tasks,
                      :final selectedListId,
                    ) =>
                      _LoadedBody(
                        lists: lists,
                        tasks: tasks,
                        selectedListId: selectedListId,
                      ),
                    TasksError(:final message, :final requiresReauth) =>
                      _ErrorView(message: message, requiresReauth: requiresReauth),
                  };
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 48,
      child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          Icon(Icons.checklist_rounded, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Tasks',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: c.textMuted),
            tooltip: 'Close',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: onClose,
          ),
        ],
      ),
      ),
    );
  }
}

class _LoadedBody extends StatelessWidget {
  const _LoadedBody({
    required this.lists,
    required this.tasks,
    required this.selectedListId,
  });

  final List<TodoTaskList> lists;
  final List<TodoTask> tasks;
  final String selectedListId;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (lists.length > 1) _ListSelector(lists: lists, selectedListId: selectedListId),
        Expanded(
          child: tasks.isEmpty
              ? const _EmptyPlaceholder()
              : _TaskList(tasks: tasks, listId: selectedListId),
        ),
        if (selectedListId.isNotEmpty) _AddTaskBar(listId: selectedListId),
      ],
    );
  }
}

class _ListSelector extends StatelessWidget {
  const _ListSelector({required this.lists, required this.selectedListId});

  final List<TodoTaskList> lists;
  final String selectedListId;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.separatorStrong, width: 1)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: lists.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final list = lists[index];
          final isSelected = list.id == selectedListId;
          return GestureDetector(
            onTap: () => context
                .read<TasksBloc>()
                .add(TasksListSelected(listId: list.id)),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.accent.withValues(alpha: 0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? AppColors.accent.withValues(alpha: 0.6)
                      : c.separatorStrong,
                  width: 1,
                ),
              ),
              child: Text(
                list.displayName,
                style: TextStyle(
                  fontSize: 11,
                  color: isSelected ? AppColors.accent : c.textMuted,
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({required this.tasks, required this.listId});

  final List<TodoTask> tasks;
  final String listId;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: tasks.length,
      itemBuilder: (context, index) => _TaskTile(
        key: ValueKey(tasks[index].id),
        task: tasks[index],
      ),
    );
  }
}

class _TaskTile extends StatefulWidget {
  const _TaskTile({super.key, required this.task});

  final TodoTask task;

  @override
  State<_TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends State<_TaskTile> {
  bool _expanded = false;

  void _toggleStatus() => context.read<TasksBloc>().add(TaskStatusToggled(
        listId: widget.task.listId,
        taskId: widget.task.id,
        currentStatus: widget.task.status,
      ));

  /// Opens the linked email in the reading pane. In the detached Tasks window
  /// there is no reading pane (no EmailDetailBloc), so fall back to a hint.
  void _openLinkedEmail(String emailId) {
    try {
      context
          .read<EmailDetailBloc>()
          .add(EmailDetailLoadRequested(emailId: emailId));
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Open Tasks in the main window to view the linked email.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final task = widget.task;
    final isCompleted = task.isCompleted;

    final linkedEmailId = TaskEmailLink.emailIdFrom(task.body);
    final visibleNotes = TaskEmailLink.visibleNotes(task.body);
    final hasNotes = visibleNotes != null || linkedEmailId != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          // Tapping the row expands the notes — it no longer completes the
          // task. Only the checkbox toggles completion.
          onTap: hasNotes ? () => setState(() => _expanded = !_expanded) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: Checkbox(
                    value: isCompleted,
                    onChanged: (_) => _toggleStatus(),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    activeColor: AppColors.accent,
                    side: BorderSide(color: c.textMuted, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: TextStyle(
                          fontSize: 13,
                          color: isCompleted
                              ? c.textMuted.withValues(alpha: 0.5)
                              : c.textPrimary,
                          decoration:
                              isCompleted ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      if (task.dueDateTime != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          _formatDue(task.dueDateTime!),
                          style: TextStyle(
                            fontSize: 11,
                            color: _isDueOverdue(task.dueDateTime!)
                                ? Colors.redAccent
                                : c.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Microsoft To Do: real .eml attachment → download & open.
                if (task.hasAttachments) ...[
                  _RowIconButton(
                    icon: Icons.email_outlined,
                    tooltip: 'View source email',
                    onTap: () => context.read<TasksBloc>().add(
                          TaskEmailAttachmentTapped(
                            listId: task.listId,
                            taskId: task.id,
                          ),
                        ),
                  ),
                  const SizedBox(width: 2),
                ]
                // Google Tasks: linked email via notes → open in reading pane.
                else if (linkedEmailId != null) ...[
                  _RowIconButton(
                    icon: Icons.email_outlined,
                    tooltip: 'View source email',
                    onTap: () => _openLinkedEmail(linkedEmailId),
                  ),
                  const SizedBox(width: 2),
                ],
                FlagIconButton(
                  size: 14,
                  onTap: () {},
                  onSchedule: (date) => context.read<TasksBloc>().add(
                        TaskDueDateUpdateRequested(
                          listId: task.listId,
                          taskId: task.id,
                          dueDate: date,
                        ),
                      ),
                ),
                if (task.importance == TodoTaskImportance.high) ...[
                  const SizedBox(width: 2),
                  Icon(Icons.flag_rounded, size: 14, color: Colors.redAccent),
                ],
                if (hasNotes) ...[
                  const SizedBox(width: 2),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: c.textMuted,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_expanded && hasNotes)
          _TaskNotes(
            notes: visibleNotes,
            linkedEmailId: linkedEmailId,
            onOpenEmail: _openLinkedEmail,
          ),
      ],
    );
  }

  String _formatDue(DateTime due) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(due.year, due.month, due.day);
    final diff = dueDay.difference(today).inDays;
    if (diff == 0) return 'Due today';
    if (diff == 1) return 'Due tomorrow';
    if (diff == -1) return 'Due yesterday';
    if (diff < 0) return 'Due ${DateFormat('MMM d').format(due)}';
    return 'Due ${DateFormat('MMM d').format(due)}';
  }

  bool _isDueOverdue(DateTime due) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return due.isBefore(today);
  }
}

/// A small tap target used for the inline row icons (source-email button).
class _RowIconButton extends StatelessWidget {
  const _RowIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: 14, color: AppColors.accent),
        ),
      ),
    );
  }
}

/// The expanding notes area shown beneath a task when it is tapped.
class _TaskNotes extends StatelessWidget {
  const _TaskNotes({
    required this.notes,
    required this.linkedEmailId,
    required this.onOpenEmail,
  });

  final String? notes;
  final String? linkedEmailId;
  final void Function(String emailId) onOpenEmail;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      // Indent to line up under the title (checkbox + gap = 30px + 12 padding).
      padding: const EdgeInsets.fromLTRB(42, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (notes != null)
            Text(
              notes!,
              style: TextStyle(fontSize: 12, color: c.textMuted, height: 1.35),
            ),
          if (linkedEmailId != null) ...[
            if (notes != null) const SizedBox(height: 6),
            InkWell(
              onTap: () => onOpenEmail(linkedEmailId!),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.email_outlined, size: 13, color: AppColors.accent),
                  const SizedBox(width: 4),
                  Text(
                    'View source email',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.accent,
                      decoration: TextDecoration.underline,
                      decorationColor: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AddTaskBar extends StatefulWidget {
  const _AddTaskBar({required this.listId});

  final String listId;

  @override
  State<_AddTaskBar> createState() => _AddTaskBarState();
}

class _AddTaskBarState extends State<_AddTaskBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _controller.text.trim();
    if (title.isEmpty) return;
    context.read<TasksBloc>().add(TaskCreationRequested(
          listId: widget.listId,
          title: title,
        ));
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.separatorStrong, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.add, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: KeyboardListener(
              focusNode: FocusNode(),
              onKeyEvent: (event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter) {
                  _submit();
                }
              },
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                style: TextStyle(fontSize: 13, color: c.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Add a task',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: c.textMuted.withValues(alpha: 0.6),
                  ),
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                onSubmitted: (_) => _submit(),
                textInputAction: TextInputAction.done,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPlaceholder extends StatelessWidget {
  const _EmptyPlaceholder();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.checklist_rounded,
            size: 40,
            color: c.textMuted.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 10),
          Text(
            'No tasks',
            style: TextStyle(
              fontSize: 13,
              color: c.textMuted.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, this.requiresReauth = false});

  final String message;
  final bool requiresReauth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              requiresReauth
                  ? 'Google Tasks requires re-authorization.'
                  : message,
              style: TextStyle(fontSize: 12, color: c.textMuted),
              textAlign: TextAlign.center,
            ),
            if (requiresReauth) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () async {
                  final accountCubit = context.read<AccountCubit>();
                  final tasksBloc = context.read<TasksBloc>();
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    await accountCubit.reauthenticateActiveOAuth();
                    tasksBloc.add(const TasksLoadRequested());
                  } catch (e) {
                    // Surface the failure instead of swallowing it — a silent
                    // catch here left a cancelled/failed sign-in looking like
                    // nothing happened.
                    messenger.showSnackBar(
                      SnackBar(content: Text('Re-authorization failed: $e')),
                    );
                  }
                },
                child: const Text('Re-authorize'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
