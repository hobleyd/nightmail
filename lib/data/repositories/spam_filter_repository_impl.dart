import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/spam/bayesian_spam_filter.dart';
import '../../domain/entities/email.dart';
import '../../domain/repositories/spam_filter_repository.dart';

class SpamFilterRepositoryImpl implements SpamFilterRepository {
  final _cache = <String, BayesianSpamFilter>{};

  @override
  Future<void> trainSpam(String accountId, List<Email> emails) async {
    final filter = await _load(accountId);
    for (final email in emails) {
      filter.trainSpam(email.id, _textFor(email));
    }
    await _save(accountId, filter);
  }

  @override
  Future<void> trainHam(String accountId, List<Email> emails) async {
    final filter = await _load(accountId);
    for (final email in emails) {
      filter.trainHam(email.id, _textFor(email));
    }
    await _save(accountId, filter);
  }

  @override
  Future<Set<String>> classifyEmails(
      String accountId, List<Email> emails) async {
    final filter = await _load(accountId);
    if (!filter.hasTrainingData) return const {};
    return {
      for (final email in emails)
        if (filter.isSpam(_textFor(email))) email.id,
    };
  }

  Future<BayesianSpamFilter> _load(String accountId) async {
    if (_cache.containsKey(accountId)) return _cache[accountId]!;
    final file = await _filterFile(accountId);
    if (!await file.exists()) {
      return _cache[accountId] = BayesianSpamFilter();
    }
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return _cache[accountId] = BayesianSpamFilter.fromJson(json);
    } catch (e) {
      debugPrint('[NightMail] spam filter load error: $e');
      return _cache[accountId] = BayesianSpamFilter();
    }
  }

  Future<void> _save(String accountId, BayesianSpamFilter filter) async {
    try {
      final file = await _filterFile(accountId);
      await file.writeAsString(jsonEncode(filter.toJson()));
    } catch (e) {
      debugPrint('[NightMail] spam filter save error: $e');
    }
  }

  Future<File> _filterFile(String accountId) async {
    final dir = await getApplicationSupportDirectory();
    final safe = accountId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return File('${dir.path}/spam_filter_$safe.json');
  }

  static String _textFor(Email email) =>
      '${email.subject} ${email.bodyPreview}';
}
