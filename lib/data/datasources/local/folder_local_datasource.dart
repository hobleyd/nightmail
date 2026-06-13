import '../../../domain/entities/email_folder.dart';

abstract interface class FolderLocalDatasource {
  Future<List<EmailFolder>> getCachedFolders(String accountId);
  Future<void> cacheFolders({
    required String accountId,
    required List<EmailFolder> folders,
  });
  Future<void> clearFoldersForAccount(String accountId);
}
