import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../../domain/entities/contact_suggestion.dart';
import '../../domain/repositories/system_contacts_repository.dart';

class SystemContactsRepositoryImpl implements SystemContactsRepository {
  // Shared future so concurrent callers don't race on the permission request.
  Future<List<Contact>>? _loadFuture;

  Future<List<Contact>> _loadContacts() async {
    final status =
        await FlutterContacts.permissions.request(PermissionType.read);
    if (status != PermissionStatus.granted &&
        status != PermissionStatus.limited) {
      return [];
    }
    return FlutterContacts.getAll(
      properties: {ContactProperty.email, ContactProperty.name},
    );
  }

  @override
  Future<void> warmUp() async {
    _loadFuture ??= _loadContacts();
    await _loadFuture;
  }

  @override
  Future<List<ContactSuggestion>> search(String query) async {
    _loadFuture ??= _loadContacts();
    final contacts = await _loadFuture!;

    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];

    final results = <ContactSuggestion>[];
    for (final contact in contacts) {
      for (final email in contact.emails) {
        if (email.address.isNotEmpty &&
            (email.address.toLowerCase().contains(q) ||
                (contact.displayName ?? '').toLowerCase().contains(q))) {
          results.add(ContactSuggestion(
            address: email.address,
            name: (contact.displayName?.isEmpty ?? true)
                ? null
                : contact.displayName,
          ));
        }
      }
    }
    return results;
  }
}
