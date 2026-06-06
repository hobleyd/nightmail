import '../../models/email_folder_model.dart';
import '../../models/email_model.dart';

abstract interface class EmailRemoteDatasource {
  Future<List<EmailModel>> getEmails({
    String? folderId,
    int top = 25,
    int skip = 0,
    String? filter,
    String orderBy = 'receivedDateTime desc',
  });

  Future<EmailModel> getEmail(String id);

  Future<EmailModel> updateEmailReadStatus({
    required String id,
    required bool isRead,
  });

  Future<List<EmailFolderModel>> getMailFolders();

  Future<List<EmailFolderModel>> getChildFolders(String parentFolderId);
}
