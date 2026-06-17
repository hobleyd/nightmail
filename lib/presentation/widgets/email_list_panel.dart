import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';
import '../../infrastructure/accounts/account.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/email_list/email_list_state.dart';
import '../blocs/home/home_cubit.dart';
import '../blocs/tasks/tasks_bloc.dart';
import '../blocs/tasks/tasks_event.dart';
import '../blocs/tasks/tasks_state.dart';
import 'email_date_formatter.dart';
import 'email_list_item.dart';
import 'flag_icon_button.dart';

class EmailListPanel extends StatefulWidget {
  const EmailListPanel({
    super.key,
    required this.folderName,
    required this.selectedEmailId,
    required this.onEmailSelected,
    this.folder,
  });

  final String folderName;
  final EmailFolder? folder;
  final String? selectedEmailId;
  final ValueChanged<Email> onEmailSelected;

  @override
  State<EmailListPanel> createState() => _EmailListPanelState();
}

class _EmailListPanelState extends State<EmailListPanel> {
  final _scrollController = ScrollController();

  Set<String> _selectedEmailIds = {};
  int? _lastSelectedIndex;
  bool _isMultiSelectMode = false;

  late final bool _isAndroid;
  late final bool _isDesktop;
  late final bool _isMac;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    final platform = defaultTargetPlatform;
    _isAndroid = platform == TargetPlatform.android;
    _isMac = platform == TargetPlatform.macOS;
    _isDesktop = platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_isNearBottom) {
      context.read<EmailListBloc>().add(const EmailListLoadMoreRequested());
    }
  }

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return false;
    final max = _scrollController.position.maxScrollExtent;
    final current = _scrollController.offset;
    return current >= max - 300;
  }

  bool get _showCheckboxes => _isAndroid && _isMultiSelectMode;

  bool get _shiftPressed => HardwareKeyboard.instance.logicalKeysPressed
      .any((k) => k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight);

  bool get _modifierPressed {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    if (_isMac) {
      return keys.any((k) => k == LogicalKeyboardKey.metaLeft || k == LogicalKeyboardKey.metaRight);
    }
    return keys.any((k) => k == LogicalKeyboardKey.controlLeft || k == LogicalKeyboardKey.controlRight);
  }

  List<_ListItem> _currentFlatItems() {
    final state = context.read<EmailListBloc>().state;
    if (state is EmailListLoaded) {
      return _buildListItems(state.emails, state.expandedConversationIds);
    }
    return [];
  }

  void _handleEmailTap(Email email, int index) {
    // Android multi-select mode: tap toggles selection
    if (_isAndroid && _isMultiSelectMode) {
      setState(() {
        final ids = Set.of(_selectedEmailIds);
        if (ids.contains(email.id)) {
          ids.remove(email.id);
          if (ids.isEmpty) _isMultiSelectMode = false;
        } else {
          ids.add(email.id);
        }
        _selectedEmailIds = ids;
        _lastSelectedIndex = index;
      });
      return;
    }

    // Desktop Shift+Click: extend selection to a range
    if (_isDesktop && _shiftPressed && _lastSelectedIndex != null) {
      final items = _currentFlatItems();
      final lo = math.min(_lastSelectedIndex!, index);
      final hi = math.min(math.max(_lastSelectedIndex!, index), items.length - 1);
      final ids = Set.of(_selectedEmailIds);
      for (var i = lo; i <= hi; i++) {
        final item = items[i];
        if (item is _SingleEmailItem) ids.add(item.email.id);
        if (item is _ConversationHeaderItem) ids.add(item.latestEmail.id);
      }
      setState(() {
        _selectedEmailIds = ids;
        _lastSelectedIndex = index;
      });
      return;
    }

    // Desktop Ctrl/Cmd+Click: toggle individual selection
    if (_isDesktop && _modifierPressed) {
      setState(() {
        final ids = Set.of(_selectedEmailIds);
        if (ids.contains(email.id)) {
          ids.remove(email.id);
        } else {
          ids.add(email.id);
        }
        _selectedEmailIds = ids;
        _lastSelectedIndex = index;
      });
      return;
    }

    // Normal tap: clear multi-selection and open email in reading pane
    if (_selectedEmailIds.isNotEmpty || _isMultiSelectMode) {
      setState(() {
        _selectedEmailIds = {};
        _isMultiSelectMode = false;
      });
    }
    _lastSelectedIndex = index;
    widget.onEmailSelected(email);
  }

  void _handleEmailLongPress(Email email, int index) {
    if (!_isAndroid) return;
    setState(() {
      _isMultiSelectMode = true;
      _selectedEmailIds = {email.id};
      _lastSelectedIndex = index;
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedEmailIds = {};
      _isMultiSelectMode = false;
      _lastSelectedIndex = null;
    });
  }

  void _deleteSelected() {
    final ids = List.of(_selectedEmailIds);
    if (widget.selectedEmailId != null && ids.contains(widget.selectedEmailId)) {
      context.read<EmailDetailBloc>().add(const EmailDetailCleared());
      context.read<HomeCubit>().clearEmail();
    }
    context.read<EmailListBloc>().add(EmailListEmailsBulkDeleted(emailIds: ids));
    _clearSelection();
  }

  void _deleteSelection() {
    if (_selectedEmailIds.isNotEmpty) {
      _deleteSelected();
    } else if (widget.selectedEmailId != null) {
      context.read<EmailDetailBloc>().add(const EmailDetailCleared());
      context.read<HomeCubit>().clearEmail();
      context
          .read<EmailListBloc>()
          .add(EmailListEmailDeleted(emailId: widget.selectedEmailId!));
    }
  }

  void _reportJunkSelection() {
    final ids = _selectedEmailIds.isNotEmpty
        ? List.of(_selectedEmailIds)
        : [if (widget.selectedEmailId != null) widget.selectedEmailId!];
    if (ids.isEmpty) return;
    if (ids.contains(widget.selectedEmailId)) {
      context.read<EmailDetailBloc>().add(const EmailDetailCleared());
      context.read<HomeCubit>().clearEmail();
    }
    context
        .read<EmailListBloc>()
        .add(EmailListJunkReported(emailIds: ids));
    _clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfaceBase,
      child: BlocListener<EmailListBloc, EmailListState>(
        listenWhen: (prev, curr) {
          // Clear selection when the folder changes
          final prevId = prev is EmailListLoaded ? prev.currentFolderId : null;
          final currId = curr is EmailListLoaded ? curr.currentFolderId : null;
          return currId != null && prevId != currId;
        },
        listener: (context, state) => _clearSelection(),
        child: Column(
          children: [
            BlocSelector<EmailListBloc, EmailListState, bool>(
              selector: (s) => s is EmailListLoaded && s.isLoadingFresh,
              builder: (context, isLoadingFresh) {
                final hasSelection = _selectedEmailIds.isNotEmpty ||
                    widget.selectedEmailId != null;
                final account = context.read<AccountCubit>().state;
                final supportsJunk = account is AccountsLoaded &&
                    (account.activeAccount is GmailAccount ||
                        account.activeAccount is MicrosoftAccount);
                return _ListHeader(
                  folderName: widget.folderName,
                  isLoadingFresh: isLoadingFresh,
                  onRefresh: () => context
                      .read<EmailListBloc>()
                      .add(const EmailListRefreshRequested()),
                  onDelete: hasSelection ? _deleteSelection : null,
                  onReportJunk:
                      hasSelection && supportsJunk ? _reportJunkSelection : null,
                );
              },
            ),
            Divider(height: 1, color: c.separator),
            Expanded(
              child: BlocBuilder<EmailListBloc, EmailListState>(
                builder: (context, state) {
                  return switch (state) {
                    EmailListInitial() => const _EmptyStateView(
                        message: 'Select a folder to view emails',
                      ),
                    EmailListLoading() => Center(
                        child: CircularProgressIndicator(
                          color: AppColors.accent,
                          strokeWidth: 2,
                        ),
                      ),
                    EmailListLoaded(
                      :final emails,
                      :final isLoadingMore,
                      :final expandedConversationIds,
                    ) =>
                      emails.isEmpty
                          ? const _EmptyStateView(message: 'No emails here')
                          : _EmailListView(
                              emails: emails,
                              isLoadingMore: isLoadingMore,
                              selectedEmailId: widget.selectedEmailId,
                              selectedEmailIds: _selectedEmailIds,
                              showCheckboxes: _showCheckboxes,
                              scrollController: _scrollController,
                              onEmailTapped: _handleEmailTap,
                              onEmailLongPressed: _handleEmailLongPress,
                              expandedConversationIds: expandedConversationIds,
                              onToggleConversation: (id) => context
                                  .read<EmailListBloc>()
                                  .add(EmailListToggleConversation(conversationId: id)),
                            ),
                    EmailListError(:final message) =>
                      _ErrorView(message: message),
                  };
                },
              ),
            ),
            if (widget.folder != null) ...[
              Divider(height: 1, color: c.separator),
              _FolderCountFooter(folder: widget.folder!),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Conversation grouping logic
// ---------------------------------------------------------------------------

class _EmailConversation {
  _EmailConversation({required this.id, required this.emails});
  final String id;
  final List<Email> emails;

  Email get latest => emails.first;
  DateTime get latestDate => latest.receivedDateTime;
  bool get hasUnread => emails.any((e) => !e.isRead);
}

List<_EmailConversation> _groupIntoConversations(List<Email> emails) {
  final sorted = [...emails]
    ..sort((a, b) => b.receivedDateTime.compareTo(a.receivedDateTime));

  final map = <String, List<Email>>{};
  for (final email in sorted) {
    final key = email.conversationId ?? email.id;
    map.putIfAbsent(key, () => []).add(email);
  }

  return map.entries
      .map((e) => _EmailConversation(id: e.key, emails: e.value))
      .toList()
    ..sort((a, b) => b.latestDate.compareTo(a.latestDate));
}

// ---------------------------------------------------------------------------
// Flat list item types
// ---------------------------------------------------------------------------

sealed class _ListItem {}

class _SingleEmailItem extends _ListItem {
  _SingleEmailItem({required this.email, this.isChild = false});
  final Email email;
  final bool isChild;
}

class _ConversationHeaderItem extends _ListItem {
  _ConversationHeaderItem({
    required this.conversationId,
    required this.latestEmail,
    required this.allEmailIds,
    required this.totalCount,
    required this.isExpanded,
    required this.hasUnread,
  });
  final String conversationId;
  final Email latestEmail;
  final List<String> allEmailIds;
  final int totalCount;
  final bool isExpanded;
  final bool hasUnread;
}

List<_ListItem> _buildListItems(
  List<Email> emails,
  Set<String> expandedIds,
) {
  final conversations = _groupIntoConversations(emails);
  final items = <_ListItem>[];

  for (final conv in conversations) {
    if (conv.emails.length == 1) {
      items.add(_SingleEmailItem(email: conv.emails.first));
    } else {
      final isExpanded = expandedIds.contains(conv.id);
      items.add(_ConversationHeaderItem(
        conversationId: conv.id,
        latestEmail: conv.latest,
        allEmailIds: conv.emails.map((e) => e.id).toList(),
        totalCount: conv.emails.length,
        isExpanded: isExpanded,
        hasUnread: conv.hasUnread,
      ));
      if (isExpanded) {
        for (final email in conv.emails.skip(1)) {
          items.add(_SingleEmailItem(email: email, isChild: true));
        }
      }
    }
  }

  return items;
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

class _ListHeader extends StatelessWidget {
  const _ListHeader({
    required this.folderName,
    required this.onRefresh,
    required this.isLoadingFresh,
    this.onDelete,
    this.onReportJunk,
  });
  final String folderName;
  final VoidCallback onRefresh;
  final bool isLoadingFresh;
  final VoidCallback? onDelete;
  final VoidCallback? onReportJunk;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
      child: Row(
        children: [
          Text(
            folderName,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
          if (isLoadingFresh) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: c.textMuted,
              ),
            ),
          ],
          const Spacer(),
          if (onReportJunk != null)
            IconButton(
              icon: Icon(Icons.report_outlined, size: 18, color: c.textMuted),
              tooltip: 'Report junk',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: onReportJunk,
            ),
          if (onDelete != null)
            IconButton(
              icon: Icon(Icons.delete_outline_rounded, size: 18, color: c.textMuted),
              tooltip: 'Delete selected',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: onDelete,
            ),
          IconButton(
            icon: Icon(Icons.refresh_rounded, size: 18, color: c.textMuted),
            tooltip: 'Refresh',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

DateTime _addBusinessDays(DateTime date, int days) {
  var result = date;
  var added = 0;
  while (added < days) {
    result = result.add(const Duration(days: 1));
    if (result.weekday != DateTime.saturday && result.weekday != DateTime.sunday) {
      added++;
    }
  }
  return result;
}

void _createTaskFromEmail(BuildContext context, Email email, {DateTime? dueDate}) {
  final tasksState = context.read<TasksBloc>().state;
  if (tasksState is! TasksLoaded) return;
  final title = email.subject.isNotEmpty ? email.subject : email.from.displayName;
  context.read<TasksBloc>().add(TaskCreationRequested(
    listId: tasksState.selectedListId,
    title: title,
    dueDate: dueDate ?? _addBusinessDays(DateTime.now(), 3),
    emailId: email.id,
    emailSubject: email.subject,
  ));
}

class _EmailListView extends StatelessWidget {
  const _EmailListView({
    required this.emails,
    required this.isLoadingMore,
    required this.selectedEmailId,
    required this.selectedEmailIds,
    required this.showCheckboxes,
    required this.scrollController,
    required this.onEmailTapped,
    required this.expandedConversationIds,
    required this.onToggleConversation,
    this.onEmailLongPressed,
  });

  final List<Email> emails;
  final bool isLoadingMore;
  final String? selectedEmailId;
  final Set<String> selectedEmailIds;
  final bool showCheckboxes;
  final ScrollController scrollController;
  final void Function(Email email, int index) onEmailTapped;
  final void Function(Email email, int index)? onEmailLongPressed;
  final Set<String> expandedConversationIds;
  final ValueChanged<String> onToggleConversation;

  @override
  Widget build(BuildContext context) {
    final items = _buildListItems(emails, expandedConversationIds);
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: items.length + (isLoadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == items.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: CircularProgressIndicator(
                  color: AppColors.accent, strokeWidth: 2),
            ),
          );
        }
        final item = items[i];
        return switch (item) {
          _SingleEmailItem(:final email, :final isChild) => _DraggableEmailItem(
              key: ValueKey('drag_${email.id}'),
              emailIds: [email.id],
              dragLabel: email.subject.isNotEmpty ? email.subject : email.from.displayName,
              child: EmailListItem(
                email: email,
                isSelected: email.id == selectedEmailId,
                isMultiSelected: selectedEmailIds.contains(email.id),
                showCheckbox: showCheckboxes,
                indent: isChild ? 20.0 : 0.0,
                onTap: () => onEmailTapped(email, i),
                onLongPress: () => onEmailLongPressed?.call(email, i),
                onDelete: () {
                  if (email.id == selectedEmailId) {
                    context.read<EmailDetailBloc>().add(const EmailDetailCleared());
                    context.read<HomeCubit>().clearEmail();
                  }
                  context.read<EmailListBloc>().add(EmailListEmailDeleted(emailId: email.id));
                },
                onFlag: (date) => _createTaskFromEmail(context, email, dueDate: date),
              ),
            ),
          _ConversationHeaderItem() => _DraggableEmailItem(
              key: ValueKey('drag_conv_${item.conversationId}'),
              emailIds: item.allEmailIds,
              dragLabel: '${item.totalCount} emails – ${item.latestEmail.subject}',
              child: _ConversationHeader(
                latestEmail: item.latestEmail,
                totalCount: item.totalCount,
                isExpanded: item.isExpanded,
                hasUnread: item.hasUnread,
                isSelected: item.latestEmail.id == selectedEmailId,
                isMultiSelected: selectedEmailIds.contains(item.latestEmail.id),
                showCheckbox: showCheckboxes,
                onTap: () => onEmailTapped(item.latestEmail, i),
                onLongPress: () => onEmailLongPressed?.call(item.latestEmail, i),
                onToggleExpand: () => onToggleConversation(item.conversationId),
                onDelete: () {
                  if (item.latestEmail.id == selectedEmailId) {
                    context.read<EmailDetailBloc>().add(const EmailDetailCleared());
                    context.read<HomeCubit>().clearEmail();
                  }
                  context.read<EmailListBloc>().add(EmailListEmailDeleted(emailId: item.latestEmail.id));
                },
                onFlag: (date) => _createTaskFromEmail(context, item.latestEmail, dueDate: date),
              ),
            ),
        };
      },
    );
  }
}

class _ConversationHeader extends StatelessWidget {
  const _ConversationHeader({
    required this.latestEmail,
    required this.totalCount,
    required this.isExpanded,
    required this.hasUnread,
    required this.isSelected,
    required this.onTap,
    required this.onToggleExpand,
    required this.onDelete,
    required this.onFlag,
    this.isMultiSelected = false,
    this.showCheckbox = false,
    this.onLongPress,
  });

  final Email latestEmail;
  final int totalCount;
  final bool isExpanded;
  final bool hasUnread;
  final bool isSelected;
  final bool isMultiSelected;
  final bool showCheckbox;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onToggleExpand;
  final VoidCallback onDelete;
  final void Function(DateTime? dueDate) onFlag;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final highlighted = isSelected || isMultiSelected;
    // Use a Stack so the chevron floats over the left margin without shifting
    // the email content — conversation rows stay pixel-aligned with single emails.
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onLongPress,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: highlighted ? c.selectionEmailBg : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: isSelected ? Border.all(color: c.selectionBorder) : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  child: showCheckbox
                      ? Padding(
                          padding: const EdgeInsets.only(right: 8, top: 2),
                          child: Icon(
                            isMultiSelected
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 18,
                            color:
                                isMultiSelected ? AppColors.accent : c.textMuted,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                // Unread dot
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: 8),
                  child: AnimatedOpacity(
                    opacity: hasUnread ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              latestEmail.from.displayName,
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 13,
                                fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: c.badgeBg,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$totalCount',
                              style: TextStyle(
                                color: AppColors.accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            formatEmailDate(latestEmail.receivedDateTime),
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              latestEmail.subject,
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 12,
                                fontWeight: hasUnread ? FontWeight.w500 : FontWeight.w400,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (latestEmail.hasAttachments)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(
                                Icons.attach_file_rounded,
                                size: 12,
                                color: c.textDimmed,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        latestEmail.bodyPreview,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 11,
                          height: 1.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _ActionIcon(
                      icon: Icons.delete_outline_rounded,
                      color: c.textDimmed,
                      onTap: onDelete,
                    ),
                    const SizedBox(height: 2),
                    FlagIconButton(
                      color: c.textDimmed,
                      onTap: () => onFlag(null),
                      onSchedule: (date) => onFlag(date),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        // Chevron overlaid in the left margin — intercepts taps before the email content
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggleExpand,
            child: SizedBox(
              width: 16,
              child: Center(
                child: Icon(
                  isExpanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 12,
                  color: c.textMuted,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}


class _EmptyStateView extends StatelessWidget {
  const _EmptyStateView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Text(
        message,
        style: TextStyle(color: c.textDimmed, fontSize: 13),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: c.textMuted, size: 32),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 15, color: color),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: onTap,
    );
  }
}

class _DraggableEmailItem extends StatelessWidget {
  const _DraggableEmailItem({
    super.key,
    required this.emailIds,
    required this.dragLabel,
    required this.child,
  });

  final List<String> emailIds;
  final String dragLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Draggable<List<String>>(
      data: emailIds,
      feedback: _DragFeedback(count: emailIds.length),
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    );
  }
}

class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: AppColors.accent.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.mail_outline_rounded, size: 13, color: Colors.white),
            const SizedBox(width: 5),
            Text(
              count == 1 ? 'Move 1 email' : 'Move $count emails',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderCountFooter extends StatelessWidget {
  const _FolderCountFooter({required this.folder});
  final EmailFolder folder;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final unread = folder.unreadItemCount;
    final total = folder.totalItemCount;
    final label = unread > 0 ? '$unread unread · $total total' : '$total total';
    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}
