import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/email_list/email_list_state.dart';
import 'email_list_item.dart';

class EmailListPanel extends StatefulWidget {
  const EmailListPanel({
    super.key,
    required this.folderName,
    required this.selectedEmailId,
    required this.onEmailSelected,
  });

  final String folderName;
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
                  EmailListLoaded(:final emails, :final isLoadingMore) =>
                    emails.isEmpty
                        ? const _EmptyStateView(message: 'No emails here')
                        : _EmailListView(
                            emails: emails,
                            isLoadingMore: isLoadingMore,
                            selectedEmailId: widget.selectedEmailId,
                            scrollController: _scrollController,
                            onEmailSelected: widget.onEmailSelected,
                          ),
                  EmailListError(:final message) =>
                    _ErrorView(message: message),
                };
              },
            ),
          ),
        ],
      ),
    );
  }
}

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
  });

  final List<Email> emails;
  final bool isLoadingMore;
  final String? selectedEmailId;
  final ScrollController scrollController;
  final ValueChanged<Email> onEmailSelected;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: emails.length + (isLoadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == emails.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: CircularProgressIndicator(
                  color: AppColors.accent, strokeWidth: 2),
            ),
          );
        }
        final email = emails[i];
        return EmailListItem(
          key: ValueKey(email.id),
          email: email,
          isSelected: email.id == selectedEmailId,
          onTap: () => onEmailSelected(email),
        );
      },
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
