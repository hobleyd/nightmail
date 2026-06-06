import '../../domain/entities/email_folder.dart';

class EmailFolderModel extends EmailFolder {
  const EmailFolderModel({
    required super.id,
    required super.displayName,
    required super.totalItemCount,
    required super.unreadItemCount,
    super.parentFolderId,
    super.isHidden,
  });

  factory EmailFolderModel.fromJson(Map<String, dynamic> json) {
    return EmailFolderModel(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      totalItemCount: json['totalItemCount'] as int? ?? 0,
      unreadItemCount: json['unreadItemCount'] as int? ?? 0,
      parentFolderId: json['parentFolderId'] as String?,
      isHidden: json['isHidden'] as bool? ?? false,
    );
  }

  factory EmailFolderModel.fromEntity(EmailFolder entity) {
    return EmailFolderModel(
      id: entity.id,
      displayName: entity.displayName,
      totalItemCount: entity.totalItemCount,
      unreadItemCount: entity.unreadItemCount,
      parentFolderId: entity.parentFolderId,
      isHidden: entity.isHidden,
    );
  }
}
