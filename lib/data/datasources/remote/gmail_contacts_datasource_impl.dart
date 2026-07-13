import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../domain/entities/contact_details.dart';
import '../../../domain/entities/contact_suggestion.dart';
import '../../../infrastructure/http/google_people_http_client.dart';

class GmailContactsDatasourceImpl {
  GmailContactsDatasourceImpl({required GooglePeopleHttpClient client})
      : _dio = client.dio;

  @visibleForTesting
  GmailContactsDatasourceImpl.withDio(this._dio);

  final Dio _dio;

  static const _detailsReadMask =
      'emailAddresses,names,phoneNumbers,organizations,photos';

  Future<List<ContactSuggestion>> searchContacts(String query) async {
    final seen = <String>{};
    final results = <ContactSuggestion>[];

    debugPrint('[Contacts] searching query="$query"');

    await Future.wait([
      _searchPersonal(query, seen, results),
      _searchDirectory(query, seen, results),
      _searchOtherContacts(query, seen, results),
    ]);

    debugPrint('[Contacts] total results: ${results.length}');
    return results;
  }

  Future<void> _searchPersonal(
    String query,
    Set<String> seen,
    List<ContactSuggestion> results,
  ) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/people:searchContacts',
        queryParameters: {
          'query': query,
          'readMask': 'emailAddresses,names',
          'pageSize': 10,
        },
      );
      final before = results.length;
      _parseResults(resp.data, seen, results);
      debugPrint('[Contacts] personal: +${results.length - before} (data keys: ${resp.data?.keys.toList()})');
    } catch (e) {
      final body = e is DioException ? e.response?.data : null;
      debugPrint('[Contacts] personal error: $e${body != null ? '\n  body: $body' : ''}');
    }
  }

  Future<void> _searchDirectory(
    String query,
    Set<String> seen,
    List<ContactSuggestion> results,
  ) async {
    // Only available for Google Workspace accounts; silently skip for consumers.
    // Returns SearchDirectoryPeopleResponse: {"people": [...Person...]}
    // — different shape from searchContacts which wraps each entry in {"person": {...}}.
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/people:searchDirectoryPeople',
        queryParameters: {
          'query': query,
          'readMask': 'emailAddresses,names',
          'sources': 'DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE',
          'pageSize': 10,
        },
      );
      final before = results.length;
      _parseDirectoryResults(resp.data, seen, results);
      debugPrint('[Contacts] directory: +${results.length - before} (data keys: ${resp.data?.keys.toList()})');
    } catch (e) {
      final body = e is DioException ? e.response?.data : null;
      debugPrint('[Contacts] directory error: $e${body != null ? '\n  body: $body' : ''}');
    }
  }

  Future<void> _searchOtherContacts(
    String query,
    Set<String> seen,
    List<ContactSuggestion> results,
  ) async {
    // "Other contacts" — addresses auto-saved from email interactions,
    // which includes contacts from company/domain emails.
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/otherContacts:search',
        queryParameters: {
          'query': query,
          'readMask': 'emailAddresses,names',
          'pageSize': 10,
        },
      );
      final before = results.length;
      _parseResults(resp.data, seen, results);
      debugPrint('[Contacts] otherContacts: +${results.length - before} (data keys: ${resp.data?.keys.toList()})');
    } catch (e) {
      final body = e is DioException ? e.response?.data : null;
      debugPrint('[Contacts] otherContacts error: $e${body != null ? '\n  body: $body' : ''}');
    }
  }

  // Used by searchContacts and otherContacts:search — both wrap each entry as {"person": {...}}.
  void _parseResults(
    Map<String, dynamic>? data,
    Set<String> seen,
    List<ContactSuggestion> results,
  ) {
    if (data == null) return;
    final raw =
        (data['results'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    for (final r in raw) {
      final person = r['person'] as Map<String, dynamic>?;
      if (person == null) continue;
      _parsePerson(person, seen, results);
    }
  }

  // Used by searchDirectoryPeople — returns {"people": [...Person...]} with no wrapper.
  void _parseDirectoryResults(
    Map<String, dynamic>? data,
    Set<String> seen,
    List<ContactSuggestion> results,
  ) {
    if (data == null) return;
    final raw =
        (data['people'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    for (final person in raw) {
      _parsePerson(person, seen, results);
    }
  }

  void _parsePerson(
    Map<String, dynamic> person,
    Set<String> seen,
    List<ContactSuggestion> results,
  ) {
    final emails = (person['emailAddresses'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final names = (person['names'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final name = names.firstOrNull?['displayName'] as String?;
    for (final e in emails) {
      final address = e['value'] as String?;
      if (address == null || address.isEmpty) continue;
      if (seen.add(address.toLowerCase())) {
        results.add(ContactSuggestion(
          address: address,
          name: (name == null || name.isEmpty) ? null : name,
        ));
      }
    }
  }

  /// Looks up full contact details (job title, org, phone, photo) for a
  /// single email address, checking personal contacts, the Workspace
  /// directory, and auto-saved "other contacts" in parallel. Returns the
  /// richest match, or null if the address isn't found anywhere.
  Future<ContactDetails?> getContactDetails(String email) async {
    final results = await Future.wait([
      _lookupPersonalDetails(email),
      _lookupDirectoryDetails(email),
      _lookupOtherContactsDetails(email),
    ]);
    final matches = results.whereType<ContactDetails>().toList();
    if (matches.isEmpty) return null;
    return matches.firstWhere((d) => d.hasAnyDetail, orElse: () => matches.first);
  }

  Future<ContactDetails?> _lookupPersonalDetails(String email) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/people:searchContacts',
        queryParameters: {
          'query': email,
          'readMask': _detailsReadMask,
          'pageSize': 10,
        },
      );
      return _findMatchingPersonWrapped(resp.data, email);
    } catch (e) {
      final body = e is DioException ? e.response?.data : null;
      debugPrint('[Contacts] details personal error: $e${body != null ? '\n  body: $body' : ''}');
      return null;
    }
  }

  Future<ContactDetails?> _lookupDirectoryDetails(String email) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/people:searchDirectoryPeople',
        queryParameters: {
          'query': email,
          'readMask': _detailsReadMask,
          'sources': 'DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE',
          'pageSize': 10,
        },
      );
      return _findMatchingPersonUnwrapped(resp.data, email);
    } catch (e) {
      final body = e is DioException ? e.response?.data : null;
      debugPrint('[Contacts] details directory error: $e${body != null ? '\n  body: $body' : ''}');
      return null;
    }
  }

  Future<ContactDetails?> _lookupOtherContactsDetails(String email) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/otherContacts:search',
        queryParameters: {
          'query': email,
          'readMask': _detailsReadMask,
          'pageSize': 10,
        },
      );
      return _findMatchingPersonWrapped(resp.data, email);
    } catch (e) {
      final body = e is DioException ? e.response?.data : null;
      debugPrint('[Contacts] details otherContacts error: $e${body != null ? '\n  body: $body' : ''}');
      return null;
    }
  }

  ContactDetails? _findMatchingPersonWrapped(
      Map<String, dynamic>? data, String email) {
    if (data == null) return null;
    final raw =
        (data['results'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    for (final r in raw) {
      final person = r['person'] as Map<String, dynamic>?;
      if (person == null) continue;
      final details = _parsePersonDetails(person, email);
      if (details != null) return details;
    }
    return null;
  }

  ContactDetails? _findMatchingPersonUnwrapped(
      Map<String, dynamic>? data, String email) {
    if (data == null) return null;
    final raw =
        (data['people'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    for (final person in raw) {
      final details = _parsePersonDetails(person, email);
      if (details != null) return details;
    }
    return null;
  }

  /// Fetches the signed-in user's own profile fields (name, job title, phone
  /// numbers) from People API's `people/me`, for prefilling the Settings
  /// "Profile" section (and email signature merge tags). Best-effort —
  /// returns null on any failure.
  Future<
      ({
        String firstName,
        String lastName,
        String jobTitle,
        String phone,
        String mobile
      })?> fetchOwnSignatureProfile() async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/people/me',
        queryParameters: {'personFields': 'names,phoneNumbers,organizations'},
      );
      final data = resp.data;
      if (data == null) return null;

      final name = (data['names'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>()
          .firstOrNull;

      final org = (data['organizations'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>()
          .firstOrNull;

      final phones = (data['phoneNumbers'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final mobile = phones.firstWhere(
            (p) => (p['type'] as String?)?.toLowerCase() == 'mobile',
            orElse: () => const {},
          )['value'] as String? ??
          '';
      final phone = phones
              .map((p) => p['value'] as String?)
              .whereType<String>()
              .where((p) => p.isNotEmpty && p != mobile)
              .firstOrNull ??
          '';

      return (
        firstName: name?['givenName'] as String? ?? '',
        lastName: name?['familyName'] as String? ?? '',
        jobTitle: org?['title'] as String? ?? '',
        phone: phone,
        mobile: mobile,
      );
    } catch (e) {
      debugPrint('[Contacts] own profile fetch error: $e');
      return null;
    }
  }

  ContactDetails? _parsePersonDetails(
      Map<String, dynamic> person, String targetEmail) {
    final target = targetEmail.toLowerCase();
    final emails = (person['emailAddresses'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final matchedAddress = emails
        .map((e) => e['value'] as String?)
        .firstWhere(
          (a) => a != null && a.toLowerCase() == target,
          orElse: () => null,
        );
    if (matchedAddress == null) return null;

    final names = (person['names'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final name = names.firstOrNull?['displayName'] as String?;

    final orgs = (person['organizations'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final org = orgs.firstOrNull;

    final phones = (person['phoneNumbers'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map((p) => p['value'] as String?)
        .whereType<String>()
        .where((p) => p.isNotEmpty)
        .toList();

    final photos = (person['photos'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final photoUrl = photos.firstOrNull?['url'] as String?;

    return ContactDetails(
      address: matchedAddress,
      name: (name == null || name.isEmpty) ? null : name,
      jobTitle: org?['title'] as String?,
      department: org?['department'] as String?,
      companyName: org?['name'] as String?,
      phoneNumbers: phones,
      photoUrl: (photoUrl == null || photoUrl.isEmpty) ? null : photoUrl,
    );
  }
}
