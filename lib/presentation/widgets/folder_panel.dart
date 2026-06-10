import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email_folder.dart';
import '../../infrastructure/accounts/account.dart';
import '../../domain/usecases/send_email.dart'; // for ComposeMode
import '../blocs/account/account_cubit.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/email_list/email_list_state.dart';
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
    required this.onTasksTapped,
    this.initialExpandedIds = const {},
    this.onExpandedIdsChanged,
  });

  final String? selectedFolderId;
  final ValueChanged<EmailFolder> onFolderSelected;
  final VoidCallback onCalendarTapped;
  final VoidCallback onTasksTapped;
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
            child: BlocConsumer<AccountCubit, AccountState>(
              listenWhen: (prev, curr) {
                // Reload folders when the active account transitions from
                // needing reauth to being authenticated.
                if (prev is AccountsLoaded && curr is AccountsLoaded) {
                  final wasUnauth =
                      prev.unauthenticatedAccountIds.contains(prev.activeAccount.id);
                  final isAuth = !curr.unauthenticatedAccountIds
                      .contains(curr.activeAccount.id);
                  return wasUnauth && isAuth;
                }
                return false;
              },
              listener: (context, state) {
                context
                    .read<FolderListBloc>()
                    .add(const FolderListLoadRequested());
              },
              builder: (context, accountState) {
                final needsReauth = accountState is AccountsLoaded &&
                    accountState.activeAccountNeedsReauth;

                final folderArea = BlocBuilder<FolderListBloc, FolderListState>(
                  builder: (context, state) {
                    return switch (state) {
                      FolderListInitial() || FolderListLoading() => Center(
                          child: CircularProgressIndicator(
                            color: AppColors.accent,
                            strokeWidth: 2,
                          ),
                        ),
                      FolderListLoaded(:final folders) => _buildTree(folders),
                      FolderListError(:final message) =>
                        _ErrorView(message: message),
                    };
                  },
                );

                if (!needsReauth) return folderArea;

                final account = accountState.activeAccount;
                return ColoredBox(
                  color: const Color(0xFFFFEBEE),
                  child: _SignInPrompt(account: account),
                );
              },
            ),
          ),
          Divider(height: 1, color: c.separatorStrong),
          _SettingsFooter(
            onCalendarTapped: widget.onCalendarTapped,
            onTasksTapped: widget.onTasksTapped,
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

enum _FolderAction { deleteAll }

class _FolderItem extends StatefulWidget {
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
  State<_FolderItem> createState() => _FolderItemState();
}

class _FolderItemState extends State<_FolderItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;
  StreamSubscription<EmailListState>? _sub;
  bool _isEmptying = false;

  bool get _isTrashFolder => ['deleted items', 'trash']
      .contains(widget.folder.displayName.toLowerCase());

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub?.cancel();
    final bloc = context.read<EmailListBloc>();
    _syncShimmer(bloc.state);
    _sub = bloc.stream.listen(_syncShimmer);
  }

  void _syncShimmer(EmailListState state) {
    final emptying = state is EmailListLoaded &&
        state.emptyingFolderIds.contains(widget.folder.id);
    if (emptying == _isEmptying) return;
    setState(() => _isEmptying = emptying);
    if (emptying) {
      _shimmer.repeat();
    } else {
      _shimmer.stop();
      _shimmer.reset();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<List<String>>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) {
        context.read<EmailListBloc>().add(EmailListEmailsMoved(
              emailIds: details.data,
              destinationFolderId: widget.folder.id,
            ));
      },
      builder: (context, candidateData, _) =>
          _buildContent(context, candidateData.isNotEmpty),
    );
  }

  Widget _buildContent(BuildContext context, bool isDragHovering) {
    final c = context.colors;
    final indentWidth = widget.depth * 16.0;

    final rowContent = Row(
      children: [
        if (widget.hasChildren)
          GestureDetector(
            onTap: widget.onExpandTap,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                widget.isExpanded
                    ? Icons.expand_more_rounded
                    : Icons.chevron_right_rounded,
                size: 16,
                color: (widget.isSelected || isDragHovering)
                    ? AppColors.accent
                    : c.textMuted,
              ),
            ),
          )
        else
          const SizedBox(width: 20),
        Icon(
          _iconFor(widget.folder.displayName),
          size: 16,
          color: (widget.isSelected || isDragHovering)
              ? AppColors.accent
              : c.textMuted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            widget.folder.displayName,
            style: TextStyle(
              color: (widget.isSelected || isDragHovering)
                  ? c.textSecondary
                  : c.textTertiary,
              fontSize: 13,
              fontWeight: (widget.isSelected || isDragHovering)
                  ? FontWeight.w500
                  : FontWeight.w400,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (widget.folder.unreadItemCount > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: c.badgeBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${widget.folder.unreadItemCount}',
              style: const TextStyle(
                color: AppColors.accent,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );

    final EdgeInsets padding = EdgeInsets.only(
      left: 10 + indentWidth,
      right: 10,
      top: 8,
      bottom: 8,
    );
    const margin = EdgeInsets.symmetric(horizontal: 8, vertical: 1);
    const radius = BorderRadius.all(Radius.circular(8));

    Widget container;
    if (_isEmptying) {
      container = AnimatedBuilder(
        animation: _shimmer,
        builder: (context, child) {
          final t = _shimmer.value;
          return Container(
            margin: margin,
            padding: padding,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(-2 + t * 4, 0),
                end: Alignment(-1 + t * 4, 0),
                colors: [
                  widget.isSelected ? c.selectionBg : Colors.transparent,
                  AppColors.accent.withValues(alpha: 0.28),
                  widget.isSelected ? c.selectionBg : Colors.transparent,
                ],
              ),
              borderRadius: radius,
            ),
            child: child,
          );
        },
        child: rowContent,
      );
    } else {
      container = AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: margin,
        padding: padding,
        decoration: BoxDecoration(
          color: (widget.isSelected || isDragHovering)
              ? c.selectionBg
              : Colors.transparent,
          borderRadius: radius,
          border: isDragHovering
              ? Border.all(color: AppColors.accent, width: 1.5)
              : null,
        ),
        child: rowContent,
      );
    }

    return GestureDetector(
      onSecondaryTapUp: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: radius,
          child: container,
        ),
      ),
    );
  }

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final result = await showMenu<_FolderAction>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: _FolderAction.deleteAll,
          child: Row(
            children: [
              Icon(
                _isTrashFolder
                    ? Icons.delete_forever_outlined
                    : Icons.delete_outline_rounded,
                size: 16,
              ),
              const SizedBox(width: 8),
              const Text('Delete All', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ],
    );

    if (result == _FolderAction.deleteAll && context.mounted) {
      await _confirmDeleteAll(context);
    }
  }

  Future<void> _confirmDeleteAll(BuildContext context) async {
    final isPermanent = _isTrashFolder;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            isPermanent ? 'Permanently Delete All?' : 'Delete All?'),
        content: Text(
          isPermanent
              ? 'All emails in ${widget.folder.displayName} will be permanently deleted. This cannot be undone.'
              : 'All emails in ${widget.folder.displayName} will be moved to Deleted Items.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: isPermanent
                ? TextButton.styleFrom(foregroundColor: Colors.red)
                : null,
            child: Text(isPermanent ? 'Delete Permanently' : 'Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      context.read<EmailListBloc>().add(EmailListFolderEmptied(
            folderId: widget.folder.id,
            permanentDelete: isPermanent,
          ));
      context.read<EmailDetailBloc>().add(const EmailDetailCleared());
      context.read<FolderListBloc>().add(
            FolderListFolderEmptied(folderId: widget.folder.id),
          );
    }
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

// ---------------------------------------------------------------------------
// Sign-in prompt — shown centred when the active account needs re-auth.
// ---------------------------------------------------------------------------

class _SignInPrompt extends StatefulWidget {
  const _SignInPrompt({required this.account});
  final Account account;

  @override
  State<_SignInPrompt> createState() => _SignInPromptState();
}

class _SignInPromptState extends State<_SignInPrompt> {
  bool _loading = false;
  String? _error;

  Future<void> _reAuthenticate() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.account is ImapAccount) {
        final accountCubit = context.read<AccountCubit>();
        await showDialog<void>(
          context: context,
          builder: (ctx) => _ImapReauthDialog(accountCubit: accountCubit),
        );
      } else {
        await context.read<AccountCubit>().reauthenticateActiveOAuth();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: Color(0xFFE57373)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: _loading ? null : _reAuthenticate,
            icon: _loading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.login_rounded, size: 16),
            label: const Text('Sign in'),
          ),
        ],
      ),
    );
  }
}

class _ImapReauthDialog extends StatefulWidget {
  const _ImapReauthDialog({required this.accountCubit});
  final AccountCubit accountCubit;

  @override
  State<_ImapReauthDialog> createState() => _ImapReauthDialogState();
}

class _ImapReauthDialogState extends State<_ImapReauthDialog> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_controller.text.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.accountCubit.reauthenticateActiveImap(_controller.text);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sign In'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter your account password to reconnect.'),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Password',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Sign In'),
        ),
      ],
    );
  }
}

class _SettingsFooter extends StatelessWidget {
  const _SettingsFooter({
    required this.onCalendarTapped,
    required this.onTasksTapped,
  });

  final VoidCallback onCalendarTapped;
  final VoidCallback onTasksTapped;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accountState = context.watch<AccountCubit>().state;
    final pollerState = context.watch<MailPollerCubit>().state;
    final hasNewMail = pollerState.accountsWithNewMail.isNotEmpty;

    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
        children: [
          PopupMenuButton<int>(
            tooltip: 'Accounts',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
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
          GestureDetector(
            onSecondaryTapUp: (details) =>
                _showCalendarContextMenu(context, details.globalPosition),
            child: IconButton(
              icon: Icon(Icons.calendar_month_outlined, size: 16, color: c.textMuted),
              tooltip: 'Calendar',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onCalendarTapped,
            ),
          ),
          GestureDetector(
            onSecondaryTapUp: (details) =>
                _showTasksContextMenu(context, details.globalPosition),
            child: IconButton(
              icon: Icon(Icons.checklist_rounded, size: 16, color: c.textMuted),
              tooltip: 'Tasks',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onTasksTapped,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.settings_outlined, size: 16, color: c.textMuted),
            tooltip: 'Settings',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
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
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () =>
                context.read<AccountCubit>().signOutActiveAccount(),
          ),
        ],
      ),
    ));
  }

  Future<void> _showCalendarContextMenu(
      BuildContext context, Offset position) async {
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(
          value: 'new_window',
          child: Text('Open in New Window', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
    if (result == 'new_window') {
      await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({'type': 'calendar'}),
        ),
      );
    }
  }

  Future<void> _showTasksContextMenu(
      BuildContext context, Offset position) async {
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(
          value: 'new_window',
          child: Text('Open in New Window', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
    if (result == 'new_window') {
      await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({'type': 'tasks'}),
        ),
      );
    }
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
