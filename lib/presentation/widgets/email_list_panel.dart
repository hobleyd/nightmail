import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/email_list/email_list_state.dart';
import 'email_date_formatter.dart';
import 'email_list_item.dart';

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

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfaceBase,
      child: Column(
        children: [
          _ListHeader(
            folderName: widget.folderName,
            onRefresh: () => context
                .read<EmailListBloc>()
                .add(const EmailListRefreshRequested()),
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
                            scrollController: _scrollController,
                            onEmailSelected: widget.onEmailSelected,
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
    required this.totalCount,
    required this.isExpanded,
    required this.hasUnread,
  });
  final String conversationId;
  final Email latestEmail;
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
  const _ListHeader({required this.folderName, required this.onRefresh});
  final String folderName;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
      child: Row(
        children: [
          Text(
            folderName,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
          const Spacer(),
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

class _EmailListView extends StatelessWidget {
  const _EmailListView({
    required this.emails,
    required this.isLoadingMore,
    required this.selectedEmailId,
    required this.scrollController,
    required this.onEmailSelected,
    required this.expandedConversationIds,
    required this.onToggleConversation,
  });

  final List<Email> emails;
  final bool isLoadingMore;
  final String? selectedEmailId;
  final ScrollController scrollController;
  final ValueChanged<Email> onEmailSelected;
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
          _SingleEmailItem(:final email, :final isChild) => EmailListItem(
              key: ValueKey(email.id),
              email: email,
              isSelected: email.id == selectedEmailId,
              indent: isChild ? 20.0 : 0.0,
              onTap: () => onEmailSelected(email),
            ),
          _ConversationHeaderItem() => _ConversationHeader(
              key: ValueKey('conv_${item.conversationId}'),
              latestEmail: item.latestEmail,
              totalCount: item.totalCount,
              isExpanded: item.isExpanded,
              hasUnread: item.hasUnread,
              isSelected: item.latestEmail.id == selectedEmailId,
              onTap: () => onEmailSelected(item.latestEmail),
              onToggleExpand: () => onToggleConversation(item.conversationId),
            ),
        };
      },
    );
  }
}

class _ConversationHeader extends StatelessWidget {
  const _ConversationHeader({
    super.key,
    required this.latestEmail,
    required this.totalCount,
    required this.isExpanded,
    required this.hasUnread,
    required this.isSelected,
    required this.onTap,
    required this.onToggleExpand,
  });

  final Email latestEmail;
  final int totalCount;
  final bool isExpanded;
  final bool hasUnread;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onToggleExpand;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Use a Stack so the chevron floats over the left margin without shifting
    // the email content — conversation rows stay pixel-aligned with single emails.
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected ? c.selectionEmailBg : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: isSelected ? Border.all(color: c.selectionBorder) : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                                color: hasUnread ? c.textSecondary : c.textTertiary,
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
                            style: TextStyle(
                              color: hasUnread ? AppColors.accent : c.textDimmed,
                              fontSize: 11,
                              fontWeight: hasUnread ? FontWeight.w500 : FontWeight.w400,
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
                                color: hasUnread ? c.textBody : c.textMuted,
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
                        style: TextStyle(
                          color: c.textDimmed,
                          fontSize: 11,
                          height: 1.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
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

class _FolderCountFooter extends StatelessWidget {
  const _FolderCountFooter({required this.folder});
  final EmailFolder folder;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final unread = folder.unreadItemCount;
    final total = folder.totalItemCount;
    final label = unread > 0 ? '$unread unread · $total total' : '$total total';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        label,
        style: TextStyle(
          color: c.textDimmed,
          fontSize: 11,
        ),
      ),
    );
  }
}
