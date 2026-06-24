import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/entities/email.dart';

class AppSettings {
  static const int defaultPollIntervalSeconds = 30;
  static const String _pollIntervalFile = 'poll_interval';

  static const bool defaultConfirmDeleteEmail = true;
  static const String _confirmDeleteEmailFile = 'confirm_delete_email';

  static const String _externalImageDomainsFile = 'external_image_domains';

  static const EmailBodyType defaultComposeFormat = EmailBodyType.html;
  static const String _composeFormatFile = 'compose_format';

  Future<File> _file(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$name');
  }

  Future<int> loadPollIntervalSeconds() async {
    try {
      final file = await _file(_pollIntervalFile);
      if (await file.exists()) {
        final raw = (await file.readAsString()).trim();
        return int.tryParse(raw) ?? defaultPollIntervalSeconds;
      }
    } catch (_) {}
    return defaultPollIntervalSeconds;
  }

  Future<void> savePollIntervalSeconds(int seconds) async {
    try {
      final file = await _file(_pollIntervalFile);
      await file.writeAsString('$seconds');
    } catch (_) {}
  }

  Future<bool> loadConfirmDeleteEmail() async {
    try {
      final file = await _file(_confirmDeleteEmailFile);
      if (await file.exists()) {
        return (await file.readAsString()).trim() == 'true';
      }
    } catch (_) {}
    return defaultConfirmDeleteEmail;
  }

  Future<void> saveConfirmDeleteEmail(bool value) async {
    try {
      final file = await _file(_confirmDeleteEmailFile);
      await file.writeAsString('$value');
    } catch (_) {}
  }

  Future<EmailBodyType> loadDefaultComposeFormat() async {
    try {
      final file = await _file(_composeFormatFile);
      if (await file.exists()) {
        return (await file.readAsString()).trim() == 'text'
            ? EmailBodyType.text
            : EmailBodyType.html;
      }
    } catch (_) {}
    return defaultComposeFormat;
  }

  Future<void> saveDefaultComposeFormat(EmailBodyType format) async {
    try {
      final file = await _file(_composeFormatFile);
      await file.writeAsString(format == EmailBodyType.html ? 'html' : 'text');
    } catch (_) {}
  }

  Future<Set<String>> loadExternalImageDomains() async {
    try {
      final file = await _file(_externalImageDomainsFile);
      if (await file.exists()) {
        return (await file.readAsString())
            .split('\n')
            .map((d) => d.trim().toLowerCase())
            .where((d) => d.isNotEmpty)
            .toSet();
      }
    } catch (_) {}
    return {};
  }

  Future<void> saveExternalImageDomain(String domain) async {
    try {
      final domains = await loadExternalImageDomains();
      domains.add(domain.toLowerCase());
      final file = await _file(_externalImageDomainsFile);
      await file.writeAsString(domains.join('\n'));
    } catch (_) {}
  }

  Future<void> removeExternalImageDomains(Set<String> toRemove) async {
    try {
      final domains = await loadExternalImageDomains();
      domains.removeAll(toRemove);
      final file = await _file(_externalImageDomainsFile);
      await file.writeAsString(domains.join('\n'));
    } catch (_) {}
  }
}
