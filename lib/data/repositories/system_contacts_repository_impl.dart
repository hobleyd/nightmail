import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/contact_suggestion.dart';
import '../../domain/repositories/system_contacts_repository.dart';

class SystemContactsRepositoryImpl implements SystemContactsRepository {
  static const _channel =
      MethodChannel('au.com.sharpblue.nightmail/contacts');

  Future<List<Map<String, String>>>? _loadFuture;

  Future<List<Map<String, String>>> _loadContacts() async {
    final status = await _channel.invokeMethod<String>('requestPermission');
    debugPrint('[NightMail] contacts permission: $status');
    if (status == 'permanentlyDenied') {
      debugPrint(
        '[NightMail] Contacts access was denied. '
        'To enable: System Settings → Privacy & Security → Contacts → NightMail → Allow',
      );
    }
    if (status != 'granted') return [];
    return [];
  }

  @override
  Future<void> warmUp() async {
    _loadFuture ??= _loadContacts();
    await _loadFuture;
  }

  @override
  Future<List<ContactSuggestion>> search(String query) async {
    // Ensure permission has been requested.
    _loadFuture ??= _loadContacts();
    await _loadFuture;

    final q = query.trim();
    if (q.isEmpty) return [];

    try {
      final raw = await _channel.invokeMethod<List>('search', {'query': q});
      if (raw == null) return [];
      return raw
          .cast<Map>()
          .map((m) => ContactSuggestion(
                address: m['address'] as String,
                name: (m['name'] as String?)?.isEmpty ?? true
                    ? null
                    : m['name'] as String?,
              ))
          .toList();
    } catch (e) {
      debugPrint('[NightMail] contacts search error: $e');
      return [];
    }
  }
}
