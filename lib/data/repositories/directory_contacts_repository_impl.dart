import 'package:flutter/foundation.dart';

import '../../domain/entities/contact_suggestion.dart';
import '../../domain/repositories/directory_contacts_repository.dart';
import '../../infrastructure/accounts/account_manager.dart';

class DirectoryContactsRepositoryImpl implements DirectoryContactsRepository {
  DirectoryContactsRepositoryImpl({required this.accountManager});

  final AccountManager accountManager;

  @override
  Future<List<ContactSuggestion>> search(
    String query, {
    required String accountId,
  }) async {
    final ds = accountManager.contactsDatasourceForAccount(accountId);
    if (ds == null) {
      debugPrint('[Contacts] no datasource for account $accountId (not a Gmail account?)');
      return [];
    }
    return ds.searchContacts(query);
  }
}
