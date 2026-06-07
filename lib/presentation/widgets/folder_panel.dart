import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email_folder.dart';
import '../../domain/usecases/send_email.dart'; // for ComposeMode
import '../blocs/account/account_cubit.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/folder_list/folder_list_bloc.dart';
import '../blocs/folder_list/folder_list_event.dart';
import '../blocs/folder_list/folder_list_state.dart';
import '../blocs/home/home_cubit.dart';
import '../blocs/mail_poller/mail_poller_cubit.dart';
import '../blocs/theme/theme_cubit.dart';
import '../pages/settings_page.dart';
import '../pages/add_account_page.dart';

class FolderPanel extends StatefulWidget {
  const FolderPanel({
    super.key,
    required this.selectedFolderId,
    required this.onFolderSelected,
    required this.onCalendarTapped,
    this.initialExpandedIds = const {},
    this.onExpandedIdsChanged,
  });

  final String? selectedFolderId;
  final ValueChanged<EmailFolder> onFolderSelected;
  final VoidCallback onCalendarTapped;
  final Set<String> initialExpandedIds;
  final ValueChanged<Set<String>>? onExpandedIdsChanged;

  @override
  State<FolderPanel> createState() => _FolderPanelState();
}

class _FolderPanelState extends State<FolderPanel> {
  late Set<String> _expandedIds;

  @override
  void initState() {
    super.initState();
    _expandedIds = Set.of(widget.initialExpandedIds);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfacePanel,
      child: Column(
        children: [
          _PanelHeader(),
          Divider(height: 1, color: c.separatorStrong),
          Expanded(
            child: BlocBuilder<FolderListBloc, FolderListState>(
              builder: (context, state) {
                return switch (state) {
                  FolderListInitial() || FolderListLoading() =>
                    Center(
                      child: CircularProgressIndicator(
                        color: AppColors.accent,
                        strokeWidth: 2,
                      ),
                    ),
                  FolderListLoaded(:final folders) => _buildTree(folders),
                  FolderListError(:final message) => _ErrorView(message: message),
                };
              },
            ),
          ),
          Divider(height: 1, color: c.separatorStrong),
          _SettingsFooter(
            onCalendarTapped: widget.onCalendarTapped,
          ),
        ],
      ),
    );
  }

  Widget _buildTree(List<EmailFolder> folders) {
    final items = _buildDisplayList(folders);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return _FolderItem(
          folder: item.folder,
          depth: item.depth,
          isSelected: item.folder.id == widget.selectedFolderId,
          isExpanded: _expandedIds.contains(item.folder.id),
          hasChildren: item.folder.childFolderCount > 0,
          onTap: () => widget.onFolderSelected(item.folder),
          onExpandTap: () {
            setState(() {
              if (_expandedIds.contains(item.folder.id)) {
                _expandedIds.remove(item.folder.id);
              } else {
                _expandedIds.add(item.folder.id);
              }
            });
            widget.onExpandedIdsChanged?.call(_expandedIds);
          },
        );
      },
    );
  }

  List<_DisplayItem> _buildDisplayList(List<EmailFolder> all) {
    final folderById = {for (final f in all) f.id: f};
    final childrenOf = <String, List<EmailFolder>>{};
    final roots = <EmailFolder>[];

    for (final f in all) {
      if (f.parentFolderId == null || !folderById.containsKey(f.parentFolderId)) {
        roots.add(f);
      } else {
        childrenOf.putIfAbsent(f.parentFolderId!, () => []).add(f);
      }
    }

    roots.sort(_compareSystemOrder);
    for (final list in childrenOf.values) {
      list.sort((a, b) => a.displayName.compareTo(b.displayName));
    }

    final result = <_DisplayItem>[];
    void visit(EmailFolder f, int depth) {
      result.add(_DisplayItem(folder: f, depth: depth));
      if (_expandedIds.contains(f.id)) {
        for (final child in childrenOf[f.id] ?? []) {
          visit(child, depth + 1);
        }
      }
    }
    for (final root in roots) {
      visit(root, 0);
    }
    return result;
  }

  static int _compareSystemOrder(EmailFolder a, EmailFolder b) {
    final aIdx = _systemOrder(a.displayName);
    final bIdx = _systemOrder(b.displayName);
    if (aIdx != bIdx) return aIdx.compareTo(bIdx);
    return a.displayName.compareTo(b.displayName);
  }

  static int _systemOrder(String name) {
    return switch (name.toLowerCase()) {
      'inbox' => 0,
      'drafts' => 1,
      'sent items' => 2,
      'deleted items' => 3,
      'junk email' => 4,
      'archive' => 5,
      _ => 99,
    };
  }
}

class _DisplayItem {
  const _DisplayItem({required this.folder, required this.depth});
  final EmailFolder folder;
  final int depth;
}

class _PanelHeader extends StatelessWidget {
  Future<void> _openComposeWindow() async {
    await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({'mode': ComposeMode.newEmail.name}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          const Icon(Icons.mail_outline_rounded,
              size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: BlocBuilder<AccountCubit, AccountState>(
              builder: (context, state) {
                String name = 'NightMail';
                if (state is AccountsLoaded) {
                  final acc = state.activeAccount;
                  name = acc.displayName.isEmpty ? acc.emailAddress : acc.displayName;
                }
                return Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                );
              },
            ),
          ),
          IconButton(
            icon: Icon(Icons.edit_square, size: 16, color: c.textMuted),
            tooltip: 'Compose',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onPressed: () => _openComposeWindow(),
          ),
        ],
      ),
    );
  }
}

class _FolderItem extends StatelessWidget {
  const _FolderItem({
    required this.folder,
    required this.depth,
    required this.isSelected,
    required this.isExpanded,
    required this.hasChildren,
    required this.onTap,
    required this.onExpandTap,
  });

  final EmailFolder folder;
  final int depth;
  final bool isSelected;
  final bool isExpanded;
  final bool hasChildren;
  final VoidCallback onTap;
  final VoidCallback onExpandTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final indentWidth = depth * 16.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: EdgeInsets.only(
            left: 10 + indentWidth,
            right: 10,
            top: 8,
            bottom: 8,
          ),
          decoration: BoxDecoration(
            color: isSelected ? c.selectionBg : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (hasChildren)
                GestureDetector(
                  onTap: onExpandTap,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      isExpanded
                          ? Icons.expand_more_rounded
                          : Icons.chevron_right_rounded,
                      size: 16,
                      color: isSelected ? AppColors.accent : c.textMuted,
                    ),
                  ),
                )
              else
                const SizedBox(width: 20),
              Icon(
                _iconFor(folder.displayName),
                size: 16,
                color: isSelected ? AppColors.accent : c.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  folder.displayName,
                  style: TextStyle(
                    color: isSelected ? c.textSecondary : c.textTertiary,
                    fontSize: 13,
                    fontWeight:
                        isSelected ? FontWeight.w500 : FontWeight.w400,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (folder.unreadItemCount > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: c.badgeBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${folder.unreadItemCount}',
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(String name) {
    return switch (name.toLowerCase()) {
      'inbox' => Icons.inbox_rounded,
      'sent items' => Icons.send_rounded,
      'drafts' => Icons.drafts_rounded,
      'deleted items' => Icons.delete_outline_rounded,
      'junk email' => Icons.report_gmailerrorred_rounded,
      'archive' => Icons.archive_outlined,
      'outbox' => Icons.outbox_rounded,
      _ => Icons.folder_outlined,
    };
  }
}

class _SettingsFooter extends StatelessWidget {
  const _SettingsFooter({
    required this.onCalendarTapped,
  });

  final VoidCallback onCalendarTapped;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accountState = context.watch<AccountCubit>().state;
    final pollerState = context.watch<MailPollerCubit>().state;
    final hasNewMail = pollerState.accountsWithNewMail.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          PopupMenuButton<int>(
            tooltip: 'Accounts',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(Icons.manage_accounts_outlined,
                    size: 16, color: c.textMuted),
                if (hasNewMail)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            onSelected: (index) async {
              if (index == -1) {
                _showAddAccountDialog(context);
                return;
              }

              final accountCubit = context.read<AccountCubit>();
              final homeCubit = context.read<HomeCubit>();
              final pollerCubit = context.read<MailPollerCubit>();

              // Mark the selected account as viewed to clear its badge.
              final currentState = accountCubit.state;
              if (currentState is AccountsLoaded &&
                  index < currentState.accounts.length) {
                pollerCubit
                    .markAccountViewed(currentState.accounts[index].id);
              }

              // Save current folder before switching accounts.
              final prevState = accountCubit.state;
              if (prevState is AccountsLoaded) {
                final currentFolder = homeCubit.state.selectedFolderId;
                if (currentFolder != null && currentFolder.isNotEmpty) {
                  homeCubit.rememberFolderForAccount(
                      prevState.activeAccount.id, currentFolder);
                }
              }

              await accountCubit.switchToAccount(index);

              if (context.mounted) {
                final folderBloc = context.read<FolderListBloc>();
                final emailListBloc = context.read<EmailListBloc>();
                final emailDetailBloc = context.read<EmailDetailBloc>();

                final newState = accountCubit.state;
                if (newState is AccountsLoaded) {
                  homeCubit.setAccountLabel(newState.activeAccount.displayName);

                  final savedFolder = homeCubit
                      .savedFolderForAccount(newState.activeAccount.id);
                  if (savedFolder != null) {
                    homeCubit.selectFolder(savedFolder);
                    emailListBloc
                        .add(EmailListLoadRequested(folderId: savedFolder));
                  } else {
                    homeCubit.clearFolder();
                  }

                  folderBloc.add(const FolderListLoadRequested());
                  emailDetailBloc.add(const EmailDetailCleared());
                }
              }
            },
            itemBuilder: (context) {
              final newMailAccounts =
                  context.read<MailPollerCubit>().state.accountsWithNewMail;
              final items = <PopupMenuEntry<int>>[];
              if (accountState is AccountsLoaded) {
                for (int i = 0; i < accountState.accounts.length; i++) {
                  final acc = accountState.accounts[i];
                  final isActive = i == accountState.activeIndex;
                  final hasNewMailForAccount =
                      newMailAccounts.contains(acc.id);
                  items.add(
                    PopupMenuItem(
                      value: i,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              acc.displayName,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: isActive || hasNewMailForAccount
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (isActive)
                            Icon(Icons.check, size: 14, color: AppColors.accent)
                          else if (hasNewMailForAccount)
                            Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(
                                color: AppColors.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }
                items.add(const PopupMenuDivider());
              }
              items.add(
                const PopupMenuItem(
                  value: -1,
                  child: Text('Add Account', style: TextStyle(fontSize: 13)),
                ),
              );
              return items;
            },
          ),
          IconButton(
            icon: Icon(Icons.calendar_month_outlined, size: 16, color: c.textMuted),
            tooltip: 'Calendar',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onCalendarTapped,
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.settings_outlined, size: 16, color: c.textMuted),
            tooltip: 'Settings',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () {
              final themeCubit = context.read<ThemeCubit>();
              final accountCubit = context.read<AccountCubit>();
              final pollerCubit = context.read<MailPollerCubit>();
              showDialog<void>(
                context: context,
                builder: (ctx) => MultiBlocProvider(
                  providers: [
                    BlocProvider.value(value: themeCubit),
                    BlocProvider.value(value: accountCubit),
                    BlocProvider.value(value: pollerCubit),
                  ],
                  child: const SettingsDialog(),
                ),
              );
            },
          ),
          IconButton(
            icon: Icon(Icons.logout_rounded, size: 16, color: c.textMuted),
            tooltip: 'Sign out',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () =>
                context.read<AccountCubit>().signOutActiveAccount(),
          ),
        ],
      ),
    );
  }

  void _showAddAccountDialog(BuildContext context) {
    final themeCubit = context.read<ThemeCubit>();
    final accountCubit = context.read<AccountCubit>();
    showDialog<void>(
      context: context,
      builder: (ctx) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: themeCubit),
          BlocProvider.value(value: accountCubit),
        ],
        child: const AddAccountPage(),
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
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        message,
        style: TextStyle(color: c.textMuted, fontSize: 12),
      ),
    );
  }
}
