import '../../../domain/entities/email_folder.dart';

/// The folder a freshly loaded list should open on, or null to leave the
/// current selection alone.
///
/// Lives here rather than inline in `HomePage`'s `BlocListener` so the rule
/// can be exercised against a real [FolderListBloc] without building the
/// three-panel shell.
///
/// One thing stops it: a folder the user (or a previous run of this rule) has
/// already chosen. An email opened by a notification tap before the folders
/// landed does not — the folder is still wanted behind it, or the list under
/// the message (and after Back from it, on a phone) stays empty until the next
/// poll. The caller keeps the message by selecting the folder through
/// `HomeCubit.selectFolderBehindEmail` rather than `selectFolder`, which
/// constructs a new `HomeState` that zeroes `selectedEmailId`.
///
/// [preferredFolderId] is where this account was last left, so switching back
/// to it returns to that folder rather than to the Inbox. It is restored here,
/// when the list lands, rather than at the moment of the switch: a folder id
/// means nothing until the folders it names are on screen, and one saved
/// earlier in the session may since have been deleted or renamed away. Failing
/// to find it is not an error — it just falls through to the Inbox.
EmailFolder? folderToAutoSelect({
  required List<EmailFolder> folders,
  required String? selectedFolderId,
  String? preferredFolderId,
}) {
  if (folders.isEmpty) return null;
  if (selectedFolderId != null) return null;

  if (preferredFolderId != null) {
    for (final folder in folders) {
      if (folder.id == preferredFolderId) return folder;
    }
  }

  return folders.firstWhere(
    (f) => f.displayName.toLowerCase() == 'inbox',
    orElse: () => folders.first,
  );
}
