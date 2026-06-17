import '../../domain/entities/contact_suggestion.dart';
import '../../domain/repositories/directory_contacts_repository.dart';
import '../../infrastructure/accounts/account_manager.dart';

class DirectoryContactsRepositoryImpl implements DirectoryContactsRepository {
  DirectoryContactsRepositoryImpl({required this.accountManager});

  final AccountManager accountManager;

  @override
  Future<List<ContactSuggestion>> search(String query) async {
    final ds = accountManager.contactsDatasource;
    if (ds == null) return [];
    return ds.searchContacts(query);
  }
}
