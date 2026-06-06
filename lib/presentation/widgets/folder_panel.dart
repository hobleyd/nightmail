import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/email_folder.dart';
import '../blocs/folder_list/folder_list_bloc.dart';
import '../blocs/folder_list/folder_list_state.dart';

class FolderPanel extends StatefulWidget {
  const FolderPanel({
    super.key,
    required this.selectedFolderId,
    required this.onFolderSelected,
  });

  final String? selectedFolderId;
  final ValueChanged<EmailFolder> onFolderSelected;

  @override
  State<FolderPanel> createState() => _FolderPanelState();
}

class _FolderPanelState extends State<FolderPanel> {
  final Set<String> _expandedIds = {};

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF13161F),
      child: Column(
        children: [
          _PanelHeader(),
          const Divider(height: 1, color: Color(0xFF2A2D3E)),
          Expanded(
            child: BlocBuilder<FolderListBloc, FolderListState>(
              builder: (context, state) {
                return switch (state) {
                  FolderListInitial() || FolderListLoading() =>
                    const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF7C83FD),
                        strokeWidth: 2,
                      ),
                    ),
                  FolderListLoaded(:final folders) => _buildTree(folders),
                  FolderListError(:final message) => _ErrorView(message: message),
                };
              },
            ),
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
          onExpandTap: () => setState(() {
            if (_expandedIds.contains(item.folder.id)) {
              _expandedIds.remove(item.folder.id);
            } else {
              _expandedIds.add(item.folder.id);
            }
          }),
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
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          const Icon(Icons.mail_outline_rounded,
              size: 18, color: Color(0xFF7C83FD)),
          const SizedBox(width: 8),
          const Text(
            'NightMail',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.edit_square, size: 16, color: Color(0xFF6B7280)),
            tooltip: 'Compose',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onPressed: () {},
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
            color: isSelected
                ? const Color(0xFF7C83FD).withAlpha(30)
                : Colors.transparent,
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
                      color: isSelected
                          ? const Color(0xFF7C83FD)
                          : const Color(0xFF6B7280),
                    ),
                  ),
                )
              else
                const SizedBox(width: 20),
              Icon(
                _iconFor(folder.displayName),
                size: 16,
                color: isSelected
                    ? const Color(0xFF7C83FD)
                    : const Color(0xFF6B7280),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  folder.displayName,
                  style: TextStyle(
                    color: isSelected
                        ? const Color(0xFFE0E0E0)
                        : const Color(0xFF9CA3AF),
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
                    color: const Color(0xFF7C83FD).withAlpha(40),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${folder.unreadItemCount}',
                    style: const TextStyle(
                      color: Color(0xFF7C83FD),
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

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
      ),
    );
  }
}
