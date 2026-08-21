import 'package:equatable/equatable.dart';

class EmailFolder extends Equatable {
  const EmailFolder({
    required this.id,
    required this.displayName,
    required this.totalItemCount,
    required this.unreadItemCount,
    this.parentFolderId,
    this.isHidden = false,
    this.childFolderCount = 0,
  });

  final String id;
  final String displayName;
  final int totalItemCount;
  final int unreadItemCount;
  final String? parentFolderId;
  final bool isHidden;
  final int childFolderCount;

  bool get hasUnread => unreadItemCount > 0;

  /// [parentFolderId] can be set but not cleared — a folder is only ever
  /// reparented *onto* another folder, and null has to keep meaning "leave it
  /// alone" for every other caller.
  EmailFolder copyWith({
    int? totalItemCount,
    int? unreadItemCount,
    int? childFolderCount,
    String? parentFolderId,
  }) {
    return EmailFolder(
      id: id,
      displayName: displayName,
      totalItemCount: totalItemCount ?? this.totalItemCount,
      unreadItemCount: unreadItemCount ?? this.unreadItemCount,
      parentFolderId: parentFolderId ?? this.parentFolderId,
      isHidden: isHidden,
      childFolderCount: childFolderCount ?? this.childFolderCount,
    );
  }

  // [parentFolderId] and [childFolderCount] are in here because the folder
  // tree is drawn from them: a state emit that only bumps a parent's child
  // count — which is what happens when a newly created folder is inserted
  // optimistically — would otherwise compare equal and be dropped.
  @override
  List<Object?> get props => [
        id,
        displayName,
        unreadItemCount,
        totalItemCount,
        parentFolderId,
        childFolderCount,
      ];
}
