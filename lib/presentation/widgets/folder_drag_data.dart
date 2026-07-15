/// Payload for dragging a folder onto another folder to reparent it.
class FolderDragData {
  const FolderDragData({required this.folderId, required this.displayName});
  final String folderId;
  final String displayName;
}
