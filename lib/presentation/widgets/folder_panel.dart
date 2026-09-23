import 'dart:async';

import 'package:flutter/gestures.dart';

import '../../core/platform/touch_metrics.dart';
import 'package:flutter/material.dart';
import 'adaptive_alert_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../data/datasources/local/migration_local_datasource.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_folder.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../infrastructure/migration/account_migration_service.dart';
import '../../injection_container.dart';
import 'add_shared_mailbox_dialog.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import 'email_drag_data.dart';
import 'folder_drag_data.dart';
import '../blocs/email_list/email_list_state.dart';
import '../blocs/folder_list/folder_list_bloc.dart';
import '../blocs/folder_list/folder_list_event.dart';
import '../blocs/folder_list/folder_list_state.dart';
import '../blocs/home/home_cubit.dart';
import '../blocs/mail_poller/mail_poller_cubit.dart';
import '../blocs/migration/migration_cubit.dart';
import '../blocs/update/update_cubit.dart';
import '../blocs/theme/theme_cubit.dart';
import 'view_shortcut_buttons.dart';
import '../pages/settings_page.dart';
import '../pages/add_account_page.dart';
import 'migration_status_dialog.dart';

class FolderPanel extends StatefulWidget {
  const FolderPanel({
    super.key,
    required this.selectedFolderId,
    required this.onFolderSelected,
    required this.onCalendarTapped,
    required this.onTasksTapped,
    required this.onAiTapped,
    this.initialExpandedIds = const {},
    this.onExpandedIdsChanged,
  });

  final String? selectedFolderId;
  final ValueChanged<EmailFolder> onFolderSelected;
  final VoidCallback onCalendarTapped;
  final VoidCallback onTasksTapped;
  final VoidCallback onAiTapped;
  final Set<String> initialExpandedIds;
  final ValueChanged<Set<String>>? onExpandedIdsChanged;

  @override
  State<FolderPanel> createState() => _FolderPanelState();
}

class _FolderPanelState extends State<FolderPanel> {
  late Set<String> _expandedIds;
  String? _creatingChildOfId;
  String? _renamingFolderId;
  final GlobalKey _creatingRowKey = GlobalKey();
  final GlobalKey _folderListAreaKey = GlobalKey();
  final ScrollController _folderScrollController = ScrollController();
  Timer? _autoScrollTimer;
  // DragTargetDetails.offset is the drag feedback widget's anchored
  // position, not the cursor — with the default childDragAnchorStrategy an
  // email row's Draggable anchors wherever within that (wide, tall) row the
  // user grabbed it, so the reported offset can be tens of pixels off the
  // real pointer position. Track the pointer directly instead.
  Offset? _lastPointerGlobalPosition;

  // Scrolling a row into view.
  //
  // A new folder sorts in among its siblings rather than landing where the
  // editor was, and the list is routinely taller than the panel — so both the
  // editor and the folder that replaces it arrive off screen, which reads as
  // the create having done nothing.
  //
  // The panel has no id to watch for at submit time, so the create is
  // remembered by the only thing it knows (the parent and the typed name) and
  // matched against whichever state first carries the folder: the create's own
  // reply, or the reconcile fetch behind it.
  ({String parentFolderId, String displayName})? _awaitingCreate;
  // The row owed a scroll, as one of the two things it can be. Only one is
  // ever set.
  bool _revealCreatingRow = false;
  String? _revealFolderId;
  final GlobalKey _revealRowKey = GlobalKey();
  // Where that row is in the display list, and how long the list is — recorded
  // at build time because that is where the list is built, and needed by the
  // estimate below.
  int _revealIndex = -1;
  int _lastItemCount = 0;

  @override
  void initState() {
    super.initState();
    _expandedIds = Set.of(widget.initialExpandedIds);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_trackPointer);
  }

  void _trackPointer(PointerEvent event) {
    if (event is PointerMoveEvent || event is PointerDownEvent) {
      _lastPointerGlobalPosition = event.position;
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_trackPointer);
    _autoScrollTimer?.cancel();
    _folderScrollController.dispose();
    super.dispose();
  }

  bool get _hasRevealTarget => _revealCreatingRow || _revealFolderId != null;

  bool _isRevealTarget(_DisplayItem item) {
    if (_revealCreatingRow) return item.isCreating;
    final id = _revealFolderId;
    return id != null &&
        !item.isCreating &&
        item.pendingCreate == null &&
        item.folder.id == id;
  }

  void _clearReveal() {
    if (!_hasRevealTarget) return;
    setState(() {
      _revealCreatingRow = false;
      _revealFolderId = null;
    });
  }

  /// Four is enough for the estimate below to converge on any real list; it is
  /// a backstop against a row that can never be built, not a search.
  static const int _maxRevealAttempts = 4;

  /// Scrolls the row the panel currently owes a scroll to into view.
  ///
  /// The awkward half is that `ListView.builder` only builds what is on screen
  /// (plus its cache extent), so a row further away than that has no context
  /// and `Scrollable.ensureVisible` has nothing to scroll to — which is why
  /// the create's own editor used to open invisibly under a folder with enough
  /// children. So an unbuilt row is first *jumped* to, using the row's index
  /// against the list's own extent estimate (the average of the rows it has
  /// built), and positioned exactly on the next frame, when it really exists.
  ///
  /// A row already fully inside the viewport is left alone. `ensureVisible`
  /// scrolls unconditionally, so centring one would jerk the list on the
  /// common case of a folder appearing directly under its parent.
  void _revealTargetRow({int attempt = 0}) {
    if (!mounted || !_hasRevealTarget) return;
    // The editor keeps its own GlobalKey, which is also what preserves the
    // text being typed into it when the wrapper below comes and goes.
    final ctx = _revealCreatingRow
        ? _creatingRowKey.currentContext
        : _revealRowKey.currentContext;
    if (ctx != null) {
      if (!_isRowFullyVisible(ctx)) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          // Only the first attempt animates: by the second the list has
          // already jumped, and animating from there is a second movement
          // over the same distance.
          duration: attempt == 0
              ? const Duration(milliseconds: 200)
              : Duration.zero,
        );
      }
      _clearReveal();
      return;
    }
    if (attempt >= _maxRevealAttempts ||
        !_folderScrollController.hasClients ||
        _revealIndex < 0 ||
        _lastItemCount == 0) {
      _clearReveal();
      return;
    }
    final position = _folderScrollController.position;
    final extent = position.maxScrollExtent + position.viewportDimension;
    final target = ((_revealIndex + 0.5) / _lastItemCount * extent -
            position.viewportDimension / 2)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) {
      // Nothing would move, so nothing would be built and no frame would be
      // scheduled — the retry below would never fire.
      _clearReveal();
      return;
    }
    _folderScrollController.jumpTo(target);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _revealTargetRow(attempt: attempt + 1));
  }

  bool _isRowFullyVisible(BuildContext rowContext) {
    final row = rowContext.findRenderObject();
    final list = _folderListAreaKey.currentContext?.findRenderObject();
    if (row is! RenderBox ||
        list is! RenderBox ||
        !row.attached ||
        !list.attached) {
      return false;
    }
    final rowTop = row.localToGlobal(Offset.zero).dy;
    final listTop = list.localToGlobal(Offset.zero).dy;
    return rowTop >= listTop &&
        rowTop + row.size.height <= listTop + list.size.height;
  }

  /// Matches the folder the user asked for against the state that first
  /// carries it — the create's reply, or the fetch behind it — and scrolls to
  /// it. A failed create keeps [_awaitingCreate] set, so its retry button
  /// needs nothing of its own.
  void _onFolderListState(FolderListState state) {
    final awaiting = _awaitingCreate;
    if (awaiting == null ||
        state is! FolderListLoaded ||
        state.pendingCreate != null) {
      return;
    }
    final wanted = awaiting.displayName.trim().toLowerCase();
    EmailFolder? created;
    for (final f in state.folders) {
      if (f.parentFolderId == awaiting.parentFolderId &&
          f.displayName.trim().toLowerCase() == wanted) {
        created = f;
        break;
      }
    }
    if (created == null) return;
    final folder = created;
    setState(() {
      _awaitingCreate = null;
      _revealCreatingRow = false;
      _revealFolderId = folder.id;
      // A row has to be in the display list to be scrolled to, and the parent
      // may have been collapsed while the create was in flight.
      final parentId = folder.parentFolderId;
      if (parentId != null) _expandedIds.add(parentId);
    });
    widget.onExpandedIdsChanged?.call(_expandedIds);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealTargetRow());
  }

  void _startAutoScroll(bool scrollUp) {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_folderScrollController.hasClients) return;
      final position = _folderScrollController.position;
      final target = (position.pixels + (scrollUp ? -8.0 : 8.0))
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (target == position.pixels) {
        _stopAutoScroll();
        return;
      }
      _folderScrollController.jumpTo(target);
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
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
                final pollerReauthAccounts = context
                    .watch<MailPollerCubit>()
                    .state
                    .accountsNeedingReauth;
                final needsReauth = accountState is AccountsLoaded &&
                    (accountState.activeAccountNeedsReauth ||
                        pollerReauthAccounts
                            .contains(accountState.activeAccount.id));

                final folderArea =
                    BlocConsumer<FolderListBloc, FolderListState>(
                  listener: (context, state) => _onFolderListState(state),
                  builder: (context, state) {
                    return switch (state) {
                      FolderListInitial() || FolderListLoading() => Center(
                          child: CircularProgressIndicator(
                            color: AppColors.accent,
                            strokeWidth: 2,
                          ),
                        ),
                      FolderListLoaded(
                        :final folders,
                        :final isRefreshing,
                        :final pendingCreate
                      ) =>
                        _buildTree(
                          folders,
                          showUnreadCounts: !isRefreshing,
                          pendingCreate: pendingCreate,
                        ),
                      // Auth failures (expired/revoked token) show the sign-in
                      // prompt so the user can re-authenticate in one tap.
                      FolderListError(isAuthFailure: true)
                          when accountState is AccountsLoaded =>
                        ColoredBox(
                          color: const Color(0xFFFFEBEE),
                          child: _SignInPrompt(
                              account: accountState.activeAccount),
                        ),
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
            onAiTapped: widget.onAiTapped,
          ),
        ],
      ),
    );
  }

  Widget _buildTree(
    List<EmailFolder> folders, {
    bool showUnreadCounts = true,
    PendingFolderCreation? pendingCreate,
  }) {
    final items = _buildDisplayList(folders, pendingCreate);
    final folderById = {for (final f in folders) f.id: f};

    // The parent a row is drawn under: null at the top level, which is also
    // where a folder whose parent is not in the list is drawn (see
    // _buildDisplayList) — so "sibling of that row" means the root there too.
    String? parentOf(EmailFolder f) {
      final parentId = f.parentFolderId;
      return parentId != null && folderById.containsKey(parentId)
          ? parentId
          : null;
    }

    // A folder may be dropped onto [targetId] unless it would create a cycle
    // (target is the dragged folder itself or one of its descendants) or be a
    // no-op (target is already the dragged folder's parent). A null [targetId]
    // is the top level of the mailbox.
    bool canDrop(String draggedId, String? targetId) {
      if (draggedId == targetId) return false;
      final dragged = folderById[draggedId];
      if (dragged == null) return false;
      if (targetId == null) return parentOf(dragged) != null;
      if (dragged.parentFolderId == targetId) return false;
      String? cursor = targetId;
      final seen = <String>{};
      while (cursor != null && seen.add(cursor)) {
        if (cursor == draggedId) return false;
        cursor = folderById[cursor]?.parentFolderId;
      }
      return true;
    }

    _lastItemCount = items.length;
    _revealIndex = _hasRevealTarget ? items.indexWhere(_isRevealTarget) : -1;

    Widget buildRow(BuildContext context, _DisplayItem item) {
      final pending = item.pendingCreate;
      if (pending != null) {
        return _FolderPendingRow(
          depth: item.depth,
          pending: pending,
          onRetry: () => context.read<FolderListBloc>().add(
                FolderListCreateFolderRequested(
                  parentFolderId: pending.parentFolderId,
                  displayName: pending.displayName,
                ),
              ),
          onDismiss: () {
            setState(() => _awaitingCreate = null);
            context
                .read<FolderListBloc>()
                .add(const FolderListCreateFolderDismissed());
          },
        );
      }
      if (item.isCreating) {
        return _FolderCreatingRow(
          key: _creatingRowKey,
          depth: item.depth,
          onSubmit: (name) {
            // Fire the event before setState so the context is still mounted.
            context.read<FolderListBloc>().add(
                  FolderListCreateFolderRequested(
                    parentFolderId: item.folder.id,
                    displayName: name,
                  ),
                );
            setState(() {
              _creatingChildOfId = null;
              _awaitingCreate = (
                parentFolderId: item.folder.id,
                displayName: name,
              );
            });
          },
          onCancel: () => setState(() {
            _creatingChildOfId = null;
            _awaitingCreate = null;
          }),
        );
      }
      if (item.folder.id == _renamingFolderId) {
        return _FolderRenamingRow(
          depth: item.depth,
          currentName: item.folder.displayName,
          onSubmit: (name) {
            context.read<FolderListBloc>().add(
                  FolderListRenameFolderRequested(
                    folderId: item.folder.id,
                    newDisplayName: name,
                  ),
                );
            setState(() => _renamingFolderId = null);
          },
          onCancel: () => setState(() => _renamingFolderId = null),
        );
      }
      return _FolderItem(
        folder: item.folder,
        depth: item.depth,
        isSelected: item.folder.id == widget.selectedFolderId,
        isExpanded: _expandedIds.contains(item.folder.id),
        hasChildren: item.folder.childFolderCount > 0,
        showUnreadCount: showUnreadCounts,
        isDraggable: !_isSystemFolder(item.folder),
        onDragMove: _handleFolderListDragMove,
        onDragLeave: _stopAutoScroll,
        pointerPosition: () => _lastPointerGlobalPosition,
        canAcceptFolderDrop: (draggedId) =>
            canDrop(draggedId, item.folder.id),
        onFolderDropped: (draggedId) {
          context.read<FolderListBloc>().add(FolderListMoveFolderRequested(
                folderId: draggedId,
                newParentFolderId: item.folder.id,
              ));
          // Open the folder it was dropped on, or the move reads as the
          // folder disappearing: a folder you have just dragged something
          // onto is one you have not expanded, so the row lands out of
          // sight inside it. Done on the drop rather than on the reply —
          // expanding a folder is harmless if the move then fails.
          if (_expandedIds.add(item.folder.id)) {
            setState(() {});
            widget.onExpandedIdsChanged?.call(_expandedIds);
          }
        },
        // Dropping on the line under a row makes the dragged folder that
        // row's sibling — which is the only way to reach the top level, where
        // there is no folder to drop onto.
        canAcceptFolderDropAsSibling: (draggedId) =>
            canDrop(draggedId, parentOf(item.folder)),
        onFolderDroppedAsSibling: (draggedId) {
          context.read<FolderListBloc>().add(FolderListMoveFolderRequested(
                folderId: draggedId,
                // The empty string is the root sentinel, as for a create.
                newParentFolderId: parentOf(item.folder) ?? '',
              ));
        },
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
        onAddFolder: () {
          setState(() {
            _expandedIds.add(item.folder.id);
            _creatingChildOfId = item.folder.id;
            _revealFolderId = null;
            _revealCreatingRow = true;
          });
          widget.onExpandedIdsChanged?.call(_expandedIds);
          // The editor opens under the parent's last child, so a folder with
          // more children than fit on screen used to open it out of sight —
          // and out of reach, since the row it is in was never built.
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _revealTargetRow());
        },
        onRename: () => setState(() => _renamingFolderId = item.folder.id),
        onDelete: _isSystemFolder(item.folder)
            ? null
            : () => _confirmDeleteFolder(context, item.folder, folders),
      );
    }

    return ListView.builder(
      key: _folderListAreaKey,
      controller: _folderScrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final row = buildRow(context, items[i]);
        // Keyed by index rather than by matching the item again: a GlobalKey
        // that landed on two rows at once would throw. The editor row is
        // excluded — it carries its own GlobalKey, which is what keeps the
        // text being typed alive across this wrapper appearing and going.
        if (i != _revealIndex || _revealCreatingRow) return row;
        return KeyedSubtree(key: _revealRowKey, child: row);
      },
    );
  }

  /// Asks before deleting [folder], then hands the delete to the bloc.
  ///
  /// It lives here rather than on the row (where "Delete All" asks) because
  /// only the panel holds [folders], and both halves of this need the list:
  /// what else is about to go with the folder, and where to send a selection
  /// that is about to point at nothing.
  Future<void> _confirmDeleteFolder(
    BuildContext context,
    EmailFolder folder,
    List<EmailFolder> folders,
  ) async {
    final doomed = _folderAndDescendants(folder.id, folders);
    final subfolders = doomed.length - 1;
    final accountState = context.read<AccountCubit>().state;
    // What happens to the mail is the provider's rule and the two answers are
    // nothing alike, so the dialog says which one applies rather than
    // splitting the difference. A Gmail folder is a label: losing it leaves
    // every message it was on where it was.
    final keepsMessages = accountState is AccountsLoaded &&
        accountState.activeAccount is GmailAccount;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AdaptiveAlertDialog(
        title: const Text('Delete Folder?'),
        content: Text([
          if (subfolders > 0)
            '"${folder.displayName}" and the '
                '$subfolders folder${subfolders == 1 ? '' : 's'} inside it '
                'will be deleted.'
          else
            '"${folder.displayName}" will be deleted.',
          if (keepsMessages)
            'The messages in it are not deleted — they keep their other '
                'labels and stay in All Mail.'
          else
            'The messages in it will be deleted too. This cannot be undone.',
        ].join('\n\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: keepsMessages
                ? null
                : TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete Folder'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    context
        .read<FolderListBloc>()
        .add(FolderListDeleteFolderRequested(folderId: folder.id));

    // A selection pointing at a folder that is going away has to move, and it
    // moves now rather than on the provider's answer: the alternative is a
    // list pane sitting on a folder whose row has just left the panel. A
    // refused delete leaves the user on the Inbox, which is a smaller wrong
    // than a mailbox that is no longer there.
    if (!doomed.contains(widget.selectedFolderId)) return;
    final surviving = [
      for (final f in folders)
        if (!doomed.contains(f.id)) f,
    ];
    if (surviving.isEmpty) return;
    // The reading pane is left to `onFolderSelected`, which clears it for
    // every folder change already.
    widget.onFolderSelected(surviving.firstWhere(
      (f) => f.displayName.toLowerCase() == 'inbox',
      orElse: () => surviving.first,
    ));
  }

  /// [folderId] and every folder beneath it — what a delete takes with it.
  static Set<String> _folderAndDescendants(
    String folderId,
    List<EmailFolder> folders,
  ) {
    final ids = <String>{folderId};
    var grew = true;
    while (grew) {
      grew = false;
      for (final f in folders) {
        if (!ids.contains(f.id) &&
            f.parentFolderId != null &&
            ids.contains(f.parentFolderId)) {
          ids.add(f.id);
          grew = true;
        }
      }
    }
    return ids;
  }

  static const double _autoScrollHotZone = 32.0;

  void _handleFolderListDragMove() {
    final globalPosition = _lastPointerGlobalPosition;
    if (globalPosition == null) return;
    final renderObject = _folderListAreaKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) return;
    final local = renderObject.globalToLocal(globalPosition);
    final height = renderObject.size.height;
    if (local.dy < _autoScrollHotZone) {
      _startAutoScroll(true);
    } else if (local.dy > height - _autoScrollHotZone) {
      _startAutoScroll(false);
    } else {
      _stopAutoScroll();
    }
  }

  List<_DisplayItem> _buildDisplayList(
    List<EmailFolder> all,
    PendingFolderCreation? pendingCreate,
  ) {
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
        // Insert inline editor immediately after the last child (or directly
        // under the parent if it has no visible children yet).
        if (_creatingChildOfId == f.id) {
          result.add(_DisplayItem(folder: f, depth: depth + 1, isCreating: true));
        }
      }
      // Same place, for the folder whose create is in flight (or has just
      // failed): the editor is gone by then, and without this the name the
      // user typed would vanish for the length of the round trip.
      //
      // Drawn whether or not the parent is expanded, unlike the editor. A
      // failed create is only cleared by its own retry or dismiss button, so
      // hiding the row behind a disclosure triangle strands it — set in the
      // bloc, unreachable on screen, and surviving every reload by design.
      if (pendingCreate != null && pendingCreate.parentFolderId == f.id) {
        result.add(_DisplayItem(
          folder: f,
          depth: depth + 1,
          pendingCreate: pendingCreate,
        ));
      }
    }
    for (final root in roots) {
      visit(root, 0);
    }
    // Last resort: the parent the create was addressed to is not in this list
    // at all (deleted from another client while the create was failing). The
    // row still has to be reachable, since only its own buttons clear it.
    if (pendingCreate != null &&
        !result.any((item) => item.pendingCreate != null)) {
      result.add(_DisplayItem(
        folder: EmailFolder(
          id: pendingCreate.parentFolderId,
          displayName: '',
          totalItemCount: 0,
          unreadItemCount: 0,
        ),
        depth: 0,
        pendingCreate: pendingCreate,
      ));
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

  // System folders (Inbox, Sent, etc.) can be dropped onto but not dragged.
  static bool _isSystemFolder(EmailFolder f) => _systemOrder(f.displayName) != 99;
}

class _DisplayItem {
  const _DisplayItem({
    required this.folder,
    required this.depth,
    this.isCreating = false,
    this.pendingCreate,
  });

  /// The folder this row draws — or, for [isCreating] and [pendingCreate]
  /// rows, the *parent* the new folder is being created under.
  final EmailFolder folder;
  final int depth;
  final bool isCreating;
  final PendingFolderCreation? pendingCreate;
}

class _PanelHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Same signal as the Tasks icon's overdue dot, carried by the icon's
    // own colour instead of a separate dot — the account switcher this icon
    // sits beside no longer draws one of its own (see AccountMenu).
    final hasNewMail = context
        .watch<MailPollerCubit>()
        .state
        .accountsWithNewMail
        .isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Icon(Icons.mail_outline_rounded,
              size: touchIcon(18),
              color: hasNewMail ? AppColors.notification : AppColors.accent),
          const SizedBox(width: 8),
          const Expanded(child: AccountMenu()),
          IconButton(
            icon: Icon(Icons.search, size: touchIcon(18), color: c.textMuted),
            tooltip: 'Search',
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: touchTarget(24),
              minHeight: touchTarget(24),
            ),
            onPressed: () {
              final bloc = context.read<EmailListBloc>();
              if (bloc.state is EmailListLoaded) {
                bloc.add(const EmailListSearchModeActivated());
              }
            },
          ),
        ],
      ),
    );
  }
}

/// Account name + switcher, formerly a separate icon button at the bottom of
/// the panel (`_SettingsFooter`'s `manage_accounts` menu) — moved here so
/// switching accounts and adding one live behind the same control the
/// account name already suggests is clickable.
@visibleForTesting
class AccountMenu extends StatefulWidget {
  @visibleForTesting
  const AccountMenu({super.key});

  @override
  State<AccountMenu> createState() => _AccountMenuState();
}

class _AccountMenuState extends State<AccountMenu> {
  // Checked, not pushed through a bloc: this is a plain DB read (no
  // network) that only decides one menu item's label, and the job it
  // reflects can belong to any account, not just whichever pair
  // MigrationCubit's own dialog-scoped polling happens to be watching.
  //
  // No background timer: a rebuild happening to land mid-`pumpAndSettle`
  // (in this widget's own tests or anywhere else `AccountMenu` appears)
  // would keep scheduling frames and time it out. Instead this refreshes
  // once per account switch and once more right after a migration action
  // completes — the two moments the answer can actually have changed —
  // rather than continuously while the menu just sits there unopened.
  String? _checkedForAccountId;
  MigrationJobRecord? _activeMigrationJob;

  Future<void> _refreshActiveMigration(String accountId) async {
    _checkedForAccountId = accountId;
    final job =
        await sl<AccountMigrationService>().getActiveJobForSource(accountId);
    if (!mounted || _checkedForAccountId != accountId) return;
    setState(() => _activeMigrationJob = job);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accountState = context.watch<AccountCubit>().state;
    final pollerState = context.watch<MailPollerCubit>().state;
    final hasReauthIssue = pollerState.accountsNeedingReauth.isNotEmpty;

    String name = 'NightMail';
    Account? activeAccount;
    if (accountState is AccountsLoaded) {
      activeAccount = accountState.activeAccount;
      name = activeAccount.displayName.isEmpty
          ? activeAccount.emailAddress
          : activeAccount.displayName;
    }

    if (activeAccount?.id != _checkedForAccountId) {
      final id = activeAccount?.id;
      // Set synchronously so a second build before the deferred check below
      // actually runs doesn't see the same mismatch and queue another one.
      _checkedForAccountId = id;
      // Cleared for the new account immediately rather than left showing
      // the previous account's job until the deferred check below resolves.
      _activeMigrationJob = null;
      if (id != null) {
        // Deferred a frame: build() must stay synchronous, and the check
        // calls setState.
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _refreshActiveMigration(id));
      }
    }
    final activeMigrationJob = _activeMigrationJob;

    return PopupMenuButton<Object>(
      tooltip: hasReauthIssue
          ? 'Accounts (re-authorization needed)'
          : 'Accounts',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (value) async {
        if (value == 'add_account') {
          _showAddAccountDialog(context);
          return;
        }
        if (value == 'add_shared_mailbox') {
          if (activeAccount is MicrosoftAccount) {
            _showAddSharedMailboxDialog(context, activeAccount);
          }
          return;
        }
        if (value == 'migrate_account') {
          if (activeAccount != null) {
            final id = activeAccount.id;
            await _showMigrateAccountSubmenu(context, activeAccount);
            // Re-checked once the dialog closes (not right after it opens)
            // so this account's next menu-open reflects wherever the job
            // ended up — "Migration Status" if it's still going, back to
            // "Migrate Account…" if it already finished — without waiting
            // for an unrelated account switch to trigger the next check.
            unawaited(_refreshActiveMigration(id));
          }
          return;
        }
        if (value == 'migration_status') {
          if (activeAccount != null && activeMigrationJob != null) {
            final id = activeAccount.id;
            await _openMigrationStatus(
                context, activeAccount, activeMigrationJob.targetAccountId);
            unawaited(_refreshActiveMigration(id));
          }
          return;
        }
        if (value is! int) return;

        final accountCubit = context.read<AccountCubit>();
        final homeCubit = context.read<HomeCubit>();

        await accountCubit.switchToAccount(value);

        // Everything else a switch entails — remembering the folder this
        // account is being left in, dropping the selection, clearing the
        // panes, re-requesting the folder list — belongs to HomePage's
        // AccountCubit listener, which also covers the switches a
        // notification tap makes. The saved folder is restored later
        // still, once the new list has landed and the id can be checked
        // against it; restoring it here selected a folder the listener
        // then cleared, and could name one the account no longer has.
        if (context.mounted) {
          final newState = accountCubit.state;
          if (newState is AccountsLoaded) {
            homeCubit.setAccountLabel(newState.activeAccount.displayName);
          }
        }
      },
      itemBuilder: (context) {
        final pollerState = context.read<MailPollerCubit>().state;
        final newMailAccounts = pollerState.accountsWithNewMail;
        final reauthAccounts = pollerState.accountsNeedingReauth;
        final items = <PopupMenuEntry<Object>>[];
        if (accountState is AccountsLoaded) {
          for (int i = 0; i < accountState.accounts.length; i++) {
            final acc = accountState.accounts[i];
            final isActive = i == accountState.activeIndex;
            final hasNewMailForAccount = newMailAccounts.contains(acc.id);
            final needsReauthForAccount = reauthAccounts.contains(acc.id);
            items.add(
              PopupMenuItem<Object>(
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
                    if (needsReauthForAccount)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Icon(Icons.error_rounded,
                            size: touchIcon(14),
                            color: const Color(0xFFE57373)),
                      ),
                    if (isActive)
                      Icon(Icons.check,
                          size: touchIcon(14), color: AppColors.accent)
                    else if (hasNewMailForAccount)
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: AppColors.notification,
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
          const PopupMenuItem<Object>(
            value: 'add_account',
            child: Text('Add Account', style: TextStyle(fontSize: 13)),
          ),
        );
        if (activeAccount is MicrosoftAccount) {
          items.add(
            const PopupMenuItem<Object>(
              value: 'add_shared_mailbox',
              child: Text('Add Shared Mailbox…', style: TextStyle(fontSize: 13)),
            ),
          );
        }
        if (accountState is AccountsLoaded &&
            accountState.accounts.length > 1) {
          if (activeMigrationJob != null) {
            items.add(
              const PopupMenuItem<Object>(
                value: 'migration_status',
                child:
                    Text('Migration Status', style: TextStyle(fontSize: 13)),
              ),
            );
          } else if (activeAccount is! GmailAccount) {
            // Migrating *out of* a Gmail account is withheld for now. An
            // already-running job still offers "Migration Status" above, so
            // one started before this gate can still be watched and paused.
            items.add(
              const PopupMenuItem<Object>(
                value: 'migrate_account',
                child:
                    Text('Migrate Account…', style: TextStyle(fontSize: 13)),
              ),
            );
          }
        }
        return items;
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
          ),
          if (hasReauthIssue)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(Icons.error_rounded,
                  size: touchIcon(12), color: const Color(0xFFE57373)),
            ),
          const SizedBox(width: 2),
          Icon(Icons.expand_more, size: touchIcon(16), color: c.textMuted),
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

  /// [account] is the active Microsoft account — itself a shared mailbox or a
  /// directly signed-in one. Either way the new mailbox rides on whichever
  /// account actually owns credentials, so a shared mailbox's own
  /// [MicrosoftAccount.parentAccountId] is used in place of its id.
  void _showAddSharedMailboxDialog(BuildContext context, MicrosoftAccount account) {
    final trueParentId = account.parentAccountId ?? account.id;
    final accountCubit = context.read<AccountCubit>();
    final state = accountCubit.state;
    var parentLabel = account.emailAddress;
    if (state is AccountsLoaded) {
      final parent = state.accounts.cast<Account?>().firstWhere(
            (a) => a?.id == trueParentId,
            orElse: () => null,
          );
      if (parent != null) {
        parentLabel =
            parent.emailAddress.isEmpty ? parent.displayName : parent.emailAddress;
      }
    }
    showDialog<bool>(
      context: context,
      builder: (ctx) => BlocProvider.value(
        value: accountCubit,
        child: AddSharedMailboxDialog(
          parentAccountId: trueParentId,
          parentAccountLabel: parentLabel,
        ),
      ),
    );
  }

  /// `PopupMenuButton`/`PopupMenuItem` has no native nested-submenu support,
  /// so selecting "Migrate Account…" closes this menu (PopupMenuButton does
  /// that automatically on selection) and immediately opens a second
  /// `showMenu()` anchored at the same button position — reading as a
  /// submenu without introducing a new menu widget pattern into the app.
  Future<void> _showMigrateAccountSubmenu(
    BuildContext context,
    Account activeAccount,
  ) async {
    final accountState = context.read<AccountCubit>().state;
    if (accountState is! AccountsLoaded) return;
    final targets = accountState.accounts
        .where((a) => a.id != activeAccount.id)
        .toList();
    if (targets.isEmpty) return;

    final button = context.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    final selectedId = await showMenu<String>(
      context: context,
      position: position,
      items: [
        for (final target in targets)
          PopupMenuItem<String>(
            value: target.id,
            child: Text(
              target.emailAddress.isEmpty
                  ? target.displayName
                  : target.emailAddress,
              style: const TextStyle(fontSize: 13),
            ),
          ),
      ],
    );
    if (selectedId == null || !context.mounted) return;

    final target = targets.firstWhere((a) => a.id == selectedId);
    await _openMigrationStatus(context, activeAccount, target.id);
  }

  /// Starts/resumes [sourceAccountId] → [targetAccountId] (a harmless no-op
  /// against an already-running job — and the way a job left `paused` for
  /// re-authentication picks back up, since there's no listener that resumes
  /// one automatically) and shows its status dialog. Shared by the
  /// "Migrate Account…" submenu's target pick and by "Migration Status",
  /// which already knows the target and skips the picker entirely.
  Future<void> _openMigrationStatus(
    BuildContext context,
    Account sourceAccount,
    String targetAccountId,
  ) async {
    final accountState = context.read<AccountCubit>().state;
    String targetLabel = targetAccountId;
    if (accountState is AccountsLoaded) {
      final target = accountState.accounts.cast<Account?>().firstWhere(
            (a) => a?.id == targetAccountId,
            orElse: () => null,
          );
      if (target != null) {
        targetLabel =
            target.emailAddress.isEmpty ? target.displayName : target.emailAddress;
      }
    }

    final migrationCubit = sl<MigrationCubit>();
    await migrationCubit.startOrResume(sourceAccount.id, targetAccountId);
    if (!context.mounted) return;

    final sourceLabel = sourceAccount.emailAddress.isEmpty
        ? sourceAccount.displayName
        : sourceAccount.emailAddress;
    // Awaited (unlike the fire-and-forget dialogs elsewhere in this file) so
    // the caller's post-action refresh lands once the dialog closes rather
    // than the moment it opens — a job that finishes while the dialog is
    // open only reads back as 'completed' after this returns, which is what
    // flips the menu item back to "Migrate Account…" on its own instead of
    // being stuck on "Migration Status" until an unrelated account switch.
    await showDialog<void>(
      context: context,
      builder: (ctx) => BlocProvider.value(
        value: migrationCubit,
        child: MigrationStatusDialog(
          sourceAccountLabel: sourceLabel,
          targetAccountLabel: targetLabel,
        ),
      ),
    );
  }
}

enum _FolderAction { addFolder, rename, deleteFolder, deleteAll }

class _FolderItem extends StatefulWidget {
  const _FolderItem({
    required this.folder,
    required this.depth,
    required this.isSelected,
    required this.isExpanded,
    required this.hasChildren,
    required this.onTap,
    required this.onExpandTap,
    required this.onAddFolder,
    required this.onDelete,
    required this.onRename,
    required this.isDraggable,
    required this.canAcceptFolderDrop,
    required this.onFolderDropped,
    required this.canAcceptFolderDropAsSibling,
    required this.onFolderDroppedAsSibling,
    required this.pointerPosition,
    this.showUnreadCount = true,
    this.onDragMove,
    this.onDragLeave,
  });

  final EmailFolder folder;
  final int depth;
  final bool isSelected;
  final bool isExpanded;
  final bool hasChildren;
  final bool showUnreadCount;
  final bool isDraggable;
  /// Dropping *onto* the row: the dragged folder becomes this folder's child.
  final bool Function(String draggedFolderId) canAcceptFolderDrop;
  final void Function(String draggedFolderId) onFolderDropped;

  /// Dropping on the line *under* the row: the dragged folder becomes this
  /// folder's sibling — the Outlook gesture, and the only way to the root.
  final bool Function(String draggedFolderId) canAcceptFolderDropAsSibling;
  final void Function(String draggedFolderId) onFolderDroppedAsSibling;

  /// Where the pointer is, in global coordinates. `DragTargetDetails.offset`
  /// is the feedback's anchored corner, not the pointer (see the panel), and
  /// which of the two drop zones the drag is over is a question about the
  /// pointer.
  final Offset? Function() pointerPosition;
  final VoidCallback onTap;
  final VoidCallback onExpandTap;
  final VoidCallback onAddFolder;

  /// Null for a folder that may not be deleted — the system folders, which
  /// every provider refuses to delete anyway. The menu item is drawn only
  /// when this is non-null, so "can it be deleted" is asked once, here.
  final VoidCallback? onDelete;
  final VoidCallback onRename;
  // Notifies the panel while an email or folder drag hovers this row, so it
  // can re-check the (independently tracked) pointer position against the
  // list's top/bottom edge and auto-scroll if needed.
  final VoidCallback? onDragMove;
  final VoidCallback? onDragLeave;

  @override
  State<_FolderItem> createState() => _FolderItemState();
}

/// Which of a row's two folder-drop zones a drag is over. [none] is also what
/// a zone whose move would be refused reads as, so nothing lights up for a
/// drop that would do nothing.
enum _FolderDropZone { none, into, sibling }

class _FolderItemState extends State<_FolderItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;
  StreamSubscription<EmailListState>? _sub;
  bool _isEmptying = false;
  Timer? _hoverExpandTimer;
  _FolderDropZone _folderDropZone = _FolderDropZone.none;
  // Touch only: where the finger went down, and whether it then travelled far
  // enough to count as a drag rather than a press-and-release (see [build]).
  Offset? _pressPosition;
  bool _dragMoved = false;

  bool get _isTrashFolder => ['deleted items', 'trash']
      .contains(widget.folder.displayName.toLowerCase());

  /// The active account, when it is a Gmail one — the only kind that has to be
  /// asked for a scope before it can permanently delete.
  GmailAccount? _activeGmailAccount(BuildContext context) {
    final accountState = context.read<AccountCubit>().state;
    if (accountState is! AccountsLoaded) return null;
    final account = accountState.activeAccount;
    return account is GmailAccount ? account : null;
  }

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
    _hoverExpandTimer?.cancel();
    _sub?.cancel();
    _shimmer.dispose();
    super.dispose();
  }

  // File-manager-style hover-to-expand: dwelling an email drag over a
  // collapsed folder with children reveals its subfolders as drop targets.
  // Scheduled once per hover (not restarted on every onMove, which fires
  // continuously) and cancelled the moment the drag leaves or drops.
  void _scheduleHoverExpand() {
    if (!widget.hasChildren || widget.isExpanded || _hoverExpandTimer != null) {
      return;
    }
    _hoverExpandTimer = Timer(const Duration(milliseconds: 600), () {
      _hoverExpandTimer = null;
      widget.onExpandTap();
    });
  }

  void _cancelHoverExpand() {
    _hoverExpandTimer?.cancel();
    _hoverExpandTimer = null;
  }

  /// The fraction of the row's height, from the bottom, that reads as "under
  /// this row" rather than "onto it" — what Outlook does: the row highlights,
  /// and easing the drag down a little swaps that for a line beneath it.
  static const _siblingZoneFraction = 0.3;

  /// Which zone the pointer is over now, for the folder being dragged.
  _FolderDropZone _zoneFor(String draggedId) {
    final pointer = widget.pointerPosition();
    final box = context.findRenderObject();
    if (pointer == null || box is! RenderBox || !box.hasSize) {
      return widget.canAcceptFolderDrop(draggedId)
          ? _FolderDropZone.into
          : _FolderDropZone.none;
    }
    final local = box.globalToLocal(pointer);
    final underRow = local.dy > box.size.height * (1 - _siblingZoneFraction);
    if (underRow) {
      return widget.canAcceptFolderDropAsSibling(draggedId)
          ? _FolderDropZone.sibling
          : _FolderDropZone.none;
    }
    return widget.canAcceptFolderDrop(draggedId)
        ? _FolderDropZone.into
        : _FolderDropZone.none;
  }

  void _setFolderDropZone(_FolderDropZone zone) {
    if (zone == _folderDropZone) return;
    setState(() => _folderDropZone = zone);
  }

  @override
  Widget build(BuildContext context) {
    // Outer target accepts folders dragged onto this row (reparent) or onto
    // the line under it (make it a sibling); the inner target keeps the
    // existing email-move behaviour. Nested DragTargets of different payload
    // types coexist without interfering.
    //
    // A drag is accepted if *either* zone would take it — a folder's own
    // parent, say, refuses "into" (a no-op) but takes "sibling" — and which
    // one applies is decided from the pointer's position at the drop.
    Widget row = DragTarget<FolderDragData>(
      onWillAcceptWithDetails: (d) =>
          widget.canAcceptFolderDrop(d.data.folderId) ||
          widget.canAcceptFolderDropAsSibling(d.data.folderId),
      onMove: (d) {
        widget.onDragMove?.call();
        _setFolderDropZone(_zoneFor(d.data.folderId));
      },
      onLeave: (_) {
        widget.onDragLeave?.call();
        _setFolderDropZone(_FolderDropZone.none);
      },
      onAcceptWithDetails: (d) {
        widget.onDragLeave?.call();
        final zone = _zoneFor(d.data.folderId);
        _setFolderDropZone(_FolderDropZone.none);
        switch (zone) {
          case _FolderDropZone.into:
            widget.onFolderDropped(d.data.folderId);
          case _FolderDropZone.sibling:
            widget.onFolderDroppedAsSibling(d.data.folderId);
          case _FolderDropZone.none:
            break;
        }
      },
      builder: (context, folderCandidates, _) => _buildEmailDropTarget(
        context,
        folderCandidates.isNotEmpty ? _folderDropZone : _FolderDropZone.none,
      ),
    );

    if (!widget.isDraggable) return row;

    final data = FolderDragData(
      folderId: widget.folder.id,
      displayName: widget.folder.displayName,
    );
    final childWhenDragging = Opacity(
      opacity: 0.4,
      child: _buildContent(context, false),
    );
    if (!isTouchPlatform) {
      return Draggable<FolderDragData>(
        data: data,
        dragAnchorStrategy: childDragAnchorStrategy,
        feedback: _folderDragFeedback(context),
        childWhenDragging: childWhenDragging,
        child: row,
      );
    }

    // A plain Draggable claims the touch the moment it moves, so on a phone
    // the list of folders could not be scrolled at all: every swipe that
    // began on a user folder picked the folder up instead. On touch the row
    // is a LongPressDraggable — a swipe scrolls, holding still lifts the
    // folder (with a haptic) and dragging on from there moves it. That also
    // takes the long press the context menu used on touch, and the two
    // recognisers race on the same timer, so the menu moves to what iOS does
    // natively: hold, and let go without moving.
    return Listener(
      onPointerDown: (e) => _pressPosition = e.position,
      child: LongPressDraggable<FolderDragData>(
        data: data,
        dragAnchorStrategy: childDragAnchorStrategy,
        feedback: _folderDragFeedback(context),
        childWhenDragging: childWhenDragging,
        onDragStarted: () => _dragMoved = false,
        onDragUpdate: (d) {
          final start = _pressPosition;
          if (start != null &&
              (d.globalPosition - start).distance > kTouchSlop) {
            _dragMoved = true;
          }
        },
        onDraggableCanceled: (_, _) {
          final position = _pressPosition;
          if (_dragMoved || position == null || !mounted) return;
          _showContextMenu(context, position);
        },
        child: row,
      ),
    );
  }

  Widget _buildEmailDropTarget(
    BuildContext context,
    _FolderDropZone folderZone,
  ) {
    return DragTarget<EmailDragData>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (_) {
        widget.onDragMove?.call();
        _scheduleHoverExpand();
      },
      onLeave: (_) {
        widget.onDragLeave?.call();
        _cancelHoverExpand();
      },
      onAcceptWithDetails: (details) {
        widget.onDragLeave?.call();
        _cancelHoverExpand();
        final listState = context.read<EmailListBloc>().state;
        final sourceFolderId =
            listState is EmailListLoaded ? listState.currentFolderId : null;
        final moved = listState is EmailListLoaded
            ? listState.emails
                .where((e) => details.data.emailIds.contains(e.id))
                .toList()
            : const <Email>[];

        context.read<EmailListBloc>().add(EmailListEmailsMoved(
              emailIds: details.data.emailIds,
              destinationFolderId: widget.folder.id,
              conversationId: details.data.conversationId,
            ));

        if (moved.isNotEmpty &&
            sourceFolderId != null &&
            sourceFolderId != widget.folder.id) {
          final unreadMoved = moved.where((e) => !e.isRead).length;
          final folderListBloc = context.read<FolderListBloc>();
          folderListBloc.add(FolderListUnreadCountChanged(
            folderId: sourceFolderId,
            unreadCountDelta: -unreadMoved,
            totalCountDelta: -moved.length,
          ));
          folderListBloc.add(FolderListUnreadCountChanged(
            folderId: widget.folder.id,
            unreadCountDelta: unreadMoved,
            totalCountDelta: moved.length,
          ));
          if (unreadMoved > 0) {
            final folderListState = folderListBloc.state;
            final sourceFolder = folderListState is FolderListLoaded
                ? folderListState.folders
                    .where((f) => f.id == sourceFolderId)
                    .firstOrNull
                : null;
            final sourceIsInbox =
                sourceFolder?.displayName.toLowerCase() == 'inbox';
            final destIsInbox =
                widget.folder.displayName.toLowerCase() == 'inbox';
            final mailPoller = context.read<MailPollerCubit>();
            if (sourceIsInbox && !destIsInbox) {
              for (var i = 0; i < unreadMoved; i++) {
                mailPoller.decrementUnreadCount();
              }
            } else if (destIsInbox && !sourceIsInbox) {
              for (var i = 0; i < unreadMoved; i++) {
                mailPoller.incrementUnreadCount();
              }
            }
          }
        }
      },
      builder: (context, candidateData, _) => _buildContent(
        context,
        candidateData.isNotEmpty || folderZone == _FolderDropZone.into,
        showSiblingLine: folderZone == _FolderDropZone.sibling,
      ),
    );
  }

  Widget _folderDragFeedback(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.surfacePanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.accent, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_iconFor(widget.folder.displayName),
                size: touchIcon(14), color: AppColors.accent),
            const SizedBox(width: 6),
            Text(
              widget.folder.displayName,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    bool isDragHovering, {
    bool showSiblingLine = false,
  }) {
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
                size: touchIcon(16),
                color: (widget.isSelected || isDragHovering)
                    ? AppColors.accent
                    : c.textMuted,
              ),
            ),
          )
        else
          SizedBox(width: touchIcon(20)),
        Icon(
          _iconFor(widget.folder.displayName),
          size: touchIcon(16),
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
        if (widget.showUnreadCount && widget.folder.unreadItemCount > 0)
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

    if (showSiblingLine) {
      // The insertion line Outlook draws: along the row's bottom edge, starting
      // at this row's own indent so it reads as "at this level" — the dragged
      // folder sorts in among the siblings by name, so the line says where in
      // the tree, not where in the list.
      container = Stack(
        clipBehavior: Clip.none,
        children: [
          container,
          Positioned(
            left: margin.left + padding.left,
            right: margin.right,
            bottom: 0,
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Container(height: 2, color: AppColors.accent),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return GestureDetector(
      onSecondaryTapUp: (details) =>
          _showContextMenu(context, details.globalPosition),
      // Touch has no secondary button: a long press is the context menu. A
      // draggable row on touch is a LongPressDraggable, which owns the long
      // press and opens the menu itself when the finger lifts in place.
      onLongPressStart: isTouchPlatform && !widget.isDraggable
          ? (details) {
              HapticFeedback.selectionClick();
              _showContextMenu(context, details.globalPosition);
            }
          : null,
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
          value: _FolderAction.addFolder,
          child: Row(
            children: const [
              Icon(Icons.create_new_folder_outlined, size: 16),
              SizedBox(width: 8),
              Text('Add Folder', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        PopupMenuItem(
          value: _FolderAction.rename,
          child: Row(
            children: const [
              Icon(Icons.drive_file_rename_outline_rounded, size: 16),
              SizedBox(width: 8),
              Text('Rename Folder', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        if (widget.onDelete != null)
          PopupMenuItem(
            value: _FolderAction.deleteFolder,
            child: Row(
              children: const [
                Icon(Icons.folder_delete_outlined, size: 16),
                SizedBox(width: 8),
                Text('Delete Folder', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        const PopupMenuDivider(),
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

    if (!context.mounted) return;
    if (result == _FolderAction.addFolder) {
      widget.onAddFolder();
    } else if (result == _FolderAction.rename) {
      widget.onRename();
    } else if (result == _FolderAction.deleteFolder) {
      widget.onDelete?.call();
    } else if (result == _FolderAction.deleteAll) {
      await _confirmDeleteAll(context);
    }
  }

  Future<void> _confirmDeleteAll(BuildContext context) async {
    final isPermanent = _isTrashFolder;
    // Gmail is the one provider that cannot permanently delete under the
    // scopes a sign-in asks for, so emptying its trash needs a grant first —
    // and the dialog says so *before* the destructive button, rather than
    // springing a browser on someone who has just confirmed a delete.
    final gmail = isPermanent ? _activeGmailAccount(context) : null;
    final needsGrant = gmail != null &&
        !await sl<AccountManager>().hasFullMailAccess(gmail.id);
    if (!context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AdaptiveAlertDialog(
        title: Text(
            isPermanent ? 'Permanently Delete All?' : 'Delete All?'),
        content: Text(
          [
            if (isPermanent)
              'All emails in ${widget.folder.displayName} will be permanently deleted. This cannot be undone.'
            else
              'All emails in ${widget.folder.displayName} will be moved to Deleted Items.',
            if (needsGrant)
              'Google will ask you to allow NightMail to delete mail — '
                  'permanently deleting is the one thing it has not already '
                  'been given permission for.',
          ].join('\n\n'),
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

    if (confirmed != true || !context.mounted) return;

    if (needsGrant) {
      final messenger = ScaffoldMessenger.of(context);
      bool granted;
      try {
        granted = await sl<AccountManager>().requestFullMailAccess(gmail.id);
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not ask Google for permission: $e')),
        );
        return;
      }
      // Declining is an answer, not an error — and nothing has been deleted,
      // so there is nothing to undo. Going on regardless would spend the whole
      // listing to earn a 403 per page.
      if (!granted) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Permission to delete mail was not granted'),
        ));
        return;
      }
      if (!context.mounted) return;
    }

    context.read<EmailListBloc>().add(EmailListFolderEmptied(
          folderId: widget.folder.id,
          permanentDelete: isPermanent,
          folderDisplayName: widget.folder.displayName,
        ));
    context.read<EmailDetailBloc>().add(const EmailDetailCleared());
    context.read<FolderListBloc>().add(
          FolderListFolderEmptied(folderId: widget.folder.id),
        );
    if (widget.folder.displayName.toLowerCase() == 'inbox' &&
        widget.folder.unreadItemCount > 0) {
      context.read<MailPollerCubit>().updateBadgeFromFolders(0);
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
                : Icon(Icons.login_rounded, size: touchIcon(16)),
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
    return AdaptiveAlertDialog(
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
    required this.onAiTapped,
  });

  final VoidCallback onCalendarTapped;
  final VoidCallback onTasksTapped;
  final VoidCallback onAiTapped;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Red dot on the Settings icon: a newer release has been found and is
    // waiting to be downloaded, or has been downloaded and is waiting to be
    // installed. A download already in flight does not light it — see
    // AppUpdateStatus.hasActionableUpdate.
    final updateWaiting =
        context.watch<UpdateCubit>().state.hasActionableUpdate;

    return SizedBox(
      height: touchRowHeight(28),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
        children: [
          ViewShortcutButtons(
            onCalendarTapped: onCalendarTapped,
            onTasksTapped: onTasksTapped,
            onAiTapped: onAiTapped,
          ),
          const Spacer(),
          IconButton(
            // Same dot as the Tasks icon's: an update is waiting behind
            // Settings → About, which is the only place it can be acted on.
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(Icons.settings_outlined,
                    size: touchIcon(16), color: c.textMuted),
                if (updateWaiting)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: AppColors.notification,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            tooltip: updateWaiting ? 'Settings (update available)' : 'Settings',
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: touchTarget(28),
              minHeight: touchTarget(28),
            ),
            onPressed: () => SettingsDialog.open(context),
          ),
          IconButton(
            icon: Icon(Icons.logout_rounded,
                size: touchIcon(16), color: c.textMuted),
            tooltip: 'Sign out',
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: touchTarget(28),
              minHeight: touchTarget(28),
            ),
            onPressed: () =>
                context.read<AccountCubit>().signOutActiveAccount(),
          ),
        ],
      ),
    ));
  }
}

class _FolderCreatingRow extends StatefulWidget {
  const _FolderCreatingRow({
    super.key,
    required this.depth,
    required this.onSubmit,
    required this.onCancel,
  });

  final int depth;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;

  @override
  State<_FolderCreatingRow> createState() => _FolderCreatingRowState();
}

class _FolderCreatingRowState extends State<_FolderCreatingRow> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        widget.onCancel();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    // Focused outright rather than left to the TextField's `autofocus`, which
    // is only honoured while nothing else in the enclosing FocusScope holds
    // focus — and by the time an inline editor opens, something usually does:
    // the context menu it was chosen from restores focus to whatever had it
    // before, on the way out. The field then opened dead, needing a click
    // before it would take a keystroke.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final indentWidth = widget.depth * 16.0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      padding: EdgeInsets.only(
        left: 10 + indentWidth,
        right: 10,
        top: 4,
        bottom: 4,
      ),
      child: Row(
        children: [
          SizedBox(width: touchIcon(20)),
          Icon(Icons.folder_outlined,
              size: touchIcon(16), color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              style: TextStyle(color: c.textSecondary, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: AppColors.accent),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: AppColors.accent, width: 1.5),
                ),
                hintText: 'Folder name',
                hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
              ),
              onSubmitted: (value) {
                final name = value.trim();
                if (name.isNotEmpty) widget.onSubmit(name);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A folder the user has asked for, drawn while the server is being asked —
/// and, if the create failed, drawn in red with the reason rather than
/// disappearing as though nothing had been typed.
///
/// It has none of a real folder row's behaviour: no tap, no drag, no drop
/// target, no context menu. There is no server id behind it yet, so there is
/// nothing it could correctly do (see [PendingFolderCreation]).
class _FolderPendingRow extends StatelessWidget {
  const _FolderPendingRow({
    required this.depth,
    required this.pending,
    required this.onRetry,
    required this.onDismiss,
  });

  final int depth;
  final PendingFolderCreation pending;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final failed = pending.hasFailed;
    final indentWidth = depth * 16.0;

    // The whole row carries the tooltip rather than just its text: on a
    // failure the reason is the only explanation there is, and a 13px label
    // is a poor thing to have to find with the pointer.
    return Tooltip(
      message: failed
          ? "Couldn't create ${pending.displayName}: ${pending.error}"
          : 'Creating ${pending.displayName}…',
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: EdgeInsets.only(
          left: 10 + indentWidth,
          right: 10,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            SizedBox(width: touchIcon(20)),
            Icon(
              failed ? Icons.error_outline : Icons.folder_outlined,
              size: touchIcon(16),
              color: failed ? c.errorBannerText : c.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    pending.displayName,
                    style: TextStyle(
                      color: failed ? c.errorBannerText : c.textMuted,
                      fontSize: 13,
                      fontStyle: failed ? FontStyle.normal : FontStyle.italic,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  // A tooltip never shows on a touch screen, so the reason
                  // goes under the name there instead.
                  if (failed && isTouchPlatform && pending.error != null)
                    Text(
                      pending.error!,
                      style: TextStyle(
                        color: c.errorBannerText,
                        fontSize: 11,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (failed) ...[
              _PendingAction(
                icon: Icons.refresh_rounded,
                tooltip: 'Try again',
                onTap: onRetry,
              ),
              _PendingAction(
                icon: Icons.close_rounded,
                tooltip: 'Dismiss',
                onTap: onDismiss,
              ),
            ] else
              SizedBox(
                width: touchIcon(12),
                height: touchIcon(12),
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.accent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PendingAction extends StatelessWidget {
  const _PendingAction({
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
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: touchTarget(18),
          height: touchTarget(18),
          child: Center(
            child: Icon(icon,
                size: touchIcon(14), color: context.colors.textMuted),
          ),
        ),
      ),
    );
  }
}

class _FolderRenamingRow extends StatefulWidget {
  const _FolderRenamingRow({
    required this.depth,
    required this.currentName,
    required this.onSubmit,
    required this.onCancel,
  });

  final int depth;
  final String currentName;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;

  @override
  State<_FolderRenamingRow> createState() => _FolderRenamingRowState();
}

class _FolderRenamingRowState extends State<_FolderRenamingRow> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.currentName.length,
      );
    _focusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        widget.onCancel();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    // Focused outright rather than left to the TextField's `autofocus`, which
    // is only honoured while nothing else in the enclosing FocusScope holds
    // focus — and by the time an inline editor opens, something usually does:
    // the context menu it was chosen from restores focus to whatever had it
    // before, on the way out. The field then opened dead, needing a click
    // before it would take a keystroke.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final indentWidth = widget.depth * 16.0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      padding: EdgeInsets.only(
        left: 10 + indentWidth,
        right: 10,
        top: 4,
        bottom: 4,
      ),
      child: Row(
        children: [
          SizedBox(width: touchIcon(20)),
          Icon(Icons.folder_outlined,
              size: touchIcon(16), color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              style: TextStyle(color: c.textSecondary, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: AppColors.accent),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: AppColors.accent, width: 1.5),
                ),
              ),
              onSubmitted: (value) {
                final name = value.trim();
                if (name.isNotEmpty && name != widget.currentName) {
                  widget.onSubmit(name);
                } else {
                  widget.onCancel();
                }
              },
            ),
          ),
        ],
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
