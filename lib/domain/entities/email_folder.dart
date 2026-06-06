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

  @override
  List<Object?> get props => [id];
}
