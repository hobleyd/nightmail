import 'package:flutter/foundation.dart';

import '../../domain/entities/contact_details.dart';
import '../../domain/repositories/contact_details_repository.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/accounts/account_manager.dart';

class ContactDetailsRepositoryImpl implements ContactDetailsRepository {
  ContactDetailsRepositoryImpl({required this.accountManager});

  final AccountManager accountManager;

  static const _ttl = Duration(minutes: 15);
  final Map<String, ({ContactDetails? details, DateTime fetchedAt})> _cache = {};

  @override
  Future<ContactDetails?> getContactDetails({
    required String address,
    required String accountId,
  }) async {
    final key = '$accountId|${address.toLowerCase()}';
    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.fetchedAt) < _ttl) {
      return cached.details;
    }

    ContactDetails? details;
    try {
      details = await _fetch(address: address, accountId: accountId);
    } catch (e) {
      debugPrint('[NightMail] contact details error: $e');
      details = null;
    }

    _cache[key] = (details: details, fetchedAt: DateTime.now());
    return details;
  }

  Future<ContactDetails?> _fetch({
    required String address,
    required String accountId,
  }) async {
    final account = accountManager.accounts.cast<Account?>().firstWhere(
      (a) => a?.id == accountId,
      orElse: () => null,
    );

    switch (account) {
      case GmailAccount():
        final ds = accountManager.contactsDatasourceForAccount(accountId);
        return ds?.getContactDetails(address);
      case MicrosoftAccount():
        final ds = accountManager.directoryDatasourceForAccount(accountId);
        if (ds == null) return null;
        final profile = await ds.fetchDirectoryProfile(address);
        if (profile == null) return null;
        final photo = await ds.fetchDirectoryPhoto(address);
        return photo == null ? profile : profile.copyWith(photoBytes: photo);
      case ImapAccount():
      case null:
        return null;
    }
  }
}
