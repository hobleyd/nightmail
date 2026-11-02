import 'package:flutter/material.dart';

import '../../core/platform/touch_metrics.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/gmail_category_label.dart';
import '../../domain/entities/email_folder.dart';
import 'folder_display.dart';

/// Asks which folder to move a touch selection to, as a bottom sheet listing
/// the whole folder tree expanded. Answers null if the sheet is dismissed.
///
/// [currentFolderId] is left out — moving there would do nothing — along with
/// hidden folders and Gmail's inbox categories, which are browsable through
/// the folder panel but are not somewhere a message is filed.
Future<EmailFolder?> showMoveToFolderSheet(
  BuildContext context, {
  required List<EmailFolder> folders,
  String? currentFolderId,
}) {
  final rows = _folderRows(folders);
  return showModalBottomSheet<EmailFolder>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: context.colors.surfacePanel,
    // Scrollable and draggable: a mailbox can hold well over a hundred
    // folders, far more than the sheet's default half screen.
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        final c = context.colors;
        return SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Move to',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final (:folder, :depth) = rows[index];
                    final enabled = folder.id != currentFolderId;
                    return ListTile(
                      enabled: enabled,
                      contentPadding:
                          EdgeInsets.only(left: 16.0 + depth * 16, right: 16),
                      leading: Icon(
                        folderIconFor(folder.displayName),
                        size: touchIcon(18),
                        color: enabled ? c.textMuted : c.textDimmed,
                      ),
                      title: Text(
                        folder.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: enabled ? c.textPrimary : c.textDimmed,
                          fontSize: 15,
                        ),
                      ),
                      onTap: () => Navigator.of(sheetContext).pop(folder),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// The folder tree in the folder panel's order, every level expanded. The
/// current folder stays in (drawn disabled) so the folders beneath it keep
/// their place in the tree.
List<({EmailFolder folder, int depth})> _folderRows(List<EmailFolder> all) {
  final candidates = all
      .where((f) => !f.isHidden && !isGmailCategoryLabel(f.id))
      .toList();
  final byId = {for (final f in candidates) f.id: f};
  final childrenOf = <String, List<EmailFolder>>{};
  final roots = <EmailFolder>[];
  for (final f in candidates) {
    final parent = f.parentFolderId;
    if (parent == null || !byId.containsKey(parent)) {
      roots.add(f);
    } else {
      childrenOf.putIfAbsent(parent, () => []).add(f);
    }
  }
  roots.sort(compareFolderSystemOrder);
  for (final list in childrenOf.values) {
    list.sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  final rows = <({EmailFolder folder, int depth})>[];
  void visit(EmailFolder f, int depth) {
    rows.add((folder: f, depth: depth));
    for (final child in childrenOf[f.id] ?? const <EmailFolder>[]) {
      visit(child, depth + 1);
    }
  }

  for (final root in roots) {
    visit(root, 0);
  }
  return rows;
}
