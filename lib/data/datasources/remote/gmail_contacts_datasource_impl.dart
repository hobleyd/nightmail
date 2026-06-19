import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../domain/entities/contact_suggestion.dart';
import '../../../infrastructure/http/google_people_http_client.dart';

class GmailContactsDatasourceImpl {
  GmailContactsDatasourceImpl({required GooglePeopleHttpClient client})
      : _dio = client.dio;

  @visibleForTesting
  GmailContactsDatasourceImpl.withDio(this._dio);

  final Dio _dio;

  Future<List<ContactSuggestion>> searchContacts(String query) async {
    final seen = <String>{};
    final results = <ContactSuggestion>[];

    await Future.wait([
      _searchPersonal(query, seen, results),
      _searchDirectory(query, seen, results),
      _searchOtherContacts(query, seen, results),
    ]);

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
      _parseResults(resp.data, seen, results);
    } catch (_) {}
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
      _parseDirectoryResults(resp.data, seen, results);
    } catch (_) {}
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
      _parseResults(resp.data, seen, results);
    } catch (_) {}
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
}
