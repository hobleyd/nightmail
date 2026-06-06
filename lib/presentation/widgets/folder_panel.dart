import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/entities/email_folder.dart';
import '../blocs/folder_list/folder_list_bloc.dart';
import '../blocs/folder_list/folder_list_state.dart';

class FolderPanel extends StatelessWidget {
  const FolderPanel({
    super.key,
    required this.selectedFolderId,
    required this.onFolderSelected,
  });

  final String? selectedFolderId;
  final ValueChanged<EmailFolder> onFolderSelected;

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
                  FolderListLoaded(:final folders) => ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: folders.length,
                      itemBuilder: (context, i) => _FolderItem(
                        folder: folders[i],
                        isSelected: folders[i].id == selectedFolderId,
                        onTap: () => onFolderSelected(folders[i]),
                      ),
                    ),
                  FolderListError(:final message) => _ErrorView(message: message),
                };
              },
            ),
          ),
        ],
      ),
    );
  }
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
    required this.isSelected,
    required this.onTap,
  });

  final EmailFolder folder;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF7C83FD).withAlpha(30)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
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
                    fontWeight: isSelected
                        ? FontWeight.w500
                        : FontWeight.w400,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (folder.unreadItemCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 1),
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
