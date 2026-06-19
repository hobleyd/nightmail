import 'package:flutter/foundation.dart';

import '../entities/contact_suggestion.dart';
import '../repositories/directory_contacts_repository.dart';
import '../repositories/sender_repository.dart';
import '../repositories/system_contacts_repository.dart';

class SearchContacts {
  const SearchContacts({
    required this.senderRepository,
    required this.systemContactsRepository,
    required this.directoryContactsRepository,
  });

  final SenderRepository senderRepository;
  final SystemContactsRepository systemContactsRepository;
  final DirectoryContactsRepository directoryContactsRepository;

  Future<List<ContactSuggestion>> call({
    required String query,
    required String accountId,
  }) async {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return [];

    final seen = <String>{};
    final results = <ContactSuggestion>[];

    // Known senders first — already emailed them, highest relevance
    try {
      final senders = await senderRepository.getSendersForAccount(accountId);
      for (final s in senders) {
        if (s.address.toLowerCase().contains(q) ||
            s.name.toLowerCase().contains(q)) {
          if (seen.add(s.address.toLowerCase())) {
            results.add(ContactSuggestion(
              address: s.address,
              name: s.name.isEmpty ? null : s.name,
            ));
          }
        }
      }
    } catch (e) {
      debugPrint('[NightMail] known-senders search error: $e');
    }

    // System contacts (macOS address book) and directory contacts (People API)
    // run concurrently — both are fallible and either may return nothing.
    await Future.wait([
      systemContactsRepository.search(q).then((contacts) {
        for (final c in contacts) {
          if (seen.add(c.address.toLowerCase())) results.add(c);
        }
      }).catchError((Object e) {
        debugPrint('[NightMail] system-contacts search error: $e');
      }),
      directoryContactsRepository.search(q, accountId: accountId).then((contacts) {
        for (final c in contacts) {
          if (seen.add(c.address.toLowerCase())) results.add(c);
        }
      }).catchError((Object e) {
        debugPrint('[NightMail] directory-contacts search error: $e');
      }),
    ]);

    return results.take(8).toList();
  }
}
