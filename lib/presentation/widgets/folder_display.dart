import 'package:flutter/material.dart';

import '../../domain/entities/email_folder.dart';

/// Where a well-known folder sits at the top of a folder tree; 99 for any
/// other folder, which sorts after them by name.
int folderSystemOrder(String name) {
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

/// Orders a tree's top-level folders: the well-known ones first, in
/// [folderSystemOrder], then the rest by name. Shared by the folder panel and
/// the move-to-folder sheet so the two lists cannot disagree.
int compareFolderSystemOrder(EmailFolder a, EmailFolder b) {
  final aIdx = folderSystemOrder(a.displayName);
  final bIdx = folderSystemOrder(b.displayName);
  if (aIdx != bIdx) return aIdx.compareTo(bIdx);
  return a.displayName.compareTo(b.displayName);
}

/// The icon a folder row is drawn with, by display name.
IconData folderIconFor(String name) {
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
