import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/contact_suggestion.dart';
import '../../domain/repositories/system_contacts_repository.dart';

class SystemContactsRepositoryImpl implements SystemContactsRepository {
  static const _channel =
      MethodChannel('au.com.sharpblue.nightmail/contacts');

  /// Memoised permission request. The result is cached for the process
  /// lifetime because macOS only ever prompts once — a later change is made in
  /// System Settings, which restarts the app.
  Future<bool>? _permissionFuture;

  Future<bool> _requestPermission() async {
    // Channel is only implemented on macOS; skip silently on other platforms.
    if (!Platform.isMacOS) return false;
    final status = await _channel.invokeMethod<String>('requestPermission');
    debugPrint('[NightMail] contacts permission: $status');
    if (status == 'permanentlyDenied') {
      debugPrint(
        '[NightMail] Contacts access was denied. '
        'To enable: System Settings → Privacy & Security → Contacts → NightMail → Allow',
      );
    }
    return status == 'granted';
  }

  Future<bool> _ensurePermission() =>
      _permissionFuture ??= _requestPermission();

  @override
  Future<void> warmUp() async {
    await _ensurePermission();
  }

  @override
  Future<bool> isAvailable() async {
    if (!Platform.isMacOS) return false;
    return _ensurePermission();
  }

  @override
  Future<List<ContactSuggestion>> fetchAll() async {
    if (!await isAvailable()) return [];
    try {
      // Enumerating the whole address book is the same CNContactStore walk the
      // old per-keystroke search did, just done once a day instead.
      final raw = await _channel.invokeMethod<List>('fetchAll');
      return _mapResults(raw);
    } catch (e) {
      debugPrint('[NightMail] contacts fetchAll error: $e');
      return [];
    }
  }

  @override
  Future<List<ContactSuggestion>> search(String query) async {
    if (!await isAvailable()) return [];

    final q = query.trim();
    if (q.isEmpty) return [];

    try {
      final raw = await _channel.invokeMethod<List>('search', {'query': q});
      return _mapResults(raw);
    } catch (e) {
      debugPrint('[NightMail] contacts search error: $e');
      return [];
    }
  }

  List<ContactSuggestion> _mapResults(List<dynamic>? raw) {
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
  }
}
