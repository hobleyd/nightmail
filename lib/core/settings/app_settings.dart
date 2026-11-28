import 'dart:io';


import '../../domain/entities/email.dart';
import '../../core/platform/app_data_directory.dart';

class AppSettings {
  static const int defaultPollIntervalSeconds = 30;
  static const String _pollIntervalFile = 'poll_interval';

  static const bool defaultConfirmDeleteEmail = true;
  static const String _confirmDeleteEmailFile = 'confirm_delete_email';

  static const bool defaultShowMeetingReminders = true;
  static const String _showMeetingRemindersFile = 'show_meeting_reminders';

  static const bool defaultHideSignatureForInternalReplies = true;
  static const String _hideSignatureForInternalRepliesFile =
      'hide_signature_internal_replies';

  static const String _externalImageDomainsFile = 'external_image_domains';

  static const EmailBodyType defaultComposeFormat = EmailBodyType.html;
  static const String _composeFormatFile = 'compose_format';

  static const String _chatSortByNameFile = 'chat_sort_by_name';

  static const bool defaultKeepFoldersOffline = false;
  static const String _keepFoldersOfflineFile = 'keep_folders_offline';

  /// Settings > General > "Keep opened folders offline": the backfill that
  /// downloads every message of each folder the user has opened, so the list
  /// scrolls to the end from the cache. Off by default — on Gmail it spends
  /// real quota (see `FolderBackfillService`).
  Future<bool> loadKeepFoldersOffline() async {
    try {
      final file = await _file(_keepFoldersOfflineFile);
      if (await file.exists()) {
        return (await file.readAsString()).trim() == 'true';
      }
    } catch (_) {}
    return defaultKeepFoldersOffline;
  }

  Future<void> saveKeepFoldersOffline(bool value) async {
    try {
      final file = await _file(_keepFoldersOfflineFile);
      await file.writeAsString('$value');
    } catch (_) {}
  }

  /// The chat window's list A–Z rather than newest first.
  Future<bool> loadChatSortByName() async {
    try {
      final file = await _file(_chatSortByNameFile);
      if (await file.exists()) {
        return (await file.readAsString()).trim() == 'true';
      }
    } catch (_) {}
    return false;
  }

  Future<void> saveChatSortByName(bool value) async {
    try {
      final file = await _file(_chatSortByNameFile);
      await file.writeAsString('$value');
    } catch (_) {}
  }

  static const double defaultChatPaneSplit = 0.3;
  static const String _chatPaneSplitFile = 'chat_pane_split';

  /// How much of the Chat pane, under its header, the unread list takes.
  Future<double> loadChatPaneSplit() async {
    try {
      final file = await _file(_chatPaneSplitFile);
      if (await file.exists()) {
        final v = double.tryParse((await file.readAsString()).trim());
        if (v != null && v > 0 && v < 1) return v;
      }
    } catch (_) {}
    return defaultChatPaneSplit;
  }

  Future<void> saveChatPaneSplit(double value) async {
    try {
      final file = await _file(_chatPaneSplitFile);
      await file.writeAsString(value.toStringAsFixed(3));
    } catch (_) {}
  }

  Future<File> _file(String name) async {
    final dir = await appDataDirectory();
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

  Future<bool> loadShowMeetingReminders() async {
    try {
      final file = await _file(_showMeetingRemindersFile);
      if (await file.exists()) {
        return (await file.readAsString()).trim() == 'true';
      }
    } catch (_) {}
    return defaultShowMeetingReminders;
  }

  Future<void> saveShowMeetingReminders(bool value) async {
    try {
      final file = await _file(_showMeetingRemindersFile);
      await file.writeAsString('$value');
    } catch (_) {}
  }

  Future<bool> loadHideSignatureForInternalReplies() async {
    try {
      final file = await _file(_hideSignatureForInternalRepliesFile);
      if (await file.exists()) {
        return (await file.readAsString()).trim() == 'true';
      }
    } catch (_) {}
    return defaultHideSignatureForInternalReplies;
  }

  Future<void> saveHideSignatureForInternalReplies(bool value) async {
    try {
      final file = await _file(_hideSignatureForInternalRepliesFile);
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

  /// Set once Contacts access has been seen granted, so losing it later can be
  /// told apart from never having had it — see `ContactsAccessNotice`.
  static const String _contactsAccessGrantedFile = 'contacts_access_granted';

  Future<bool> loadContactsAccessGranted() async {
    try {
      final file = await _file(_contactsAccessGrantedFile);
      if (await file.exists()) {
        return (await file.readAsString()).trim() == 'true';
      }
    } catch (_) {}
    return false;
  }

  Future<void> saveContactsAccessGranted(bool value) async {
    try {
      final file = await _file(_contactsAccessGrantedFile);
      await file.writeAsString('$value');
    } catch (_) {}
  }

  static const String _activeViewFile = 'active_view';

  Future<String> loadActiveView() async {
    try {
      final file = await _file(_activeViewFile);
      if (await file.exists()) {
        return (await file.readAsString()).trim();
      }
    } catch (_) {}
    return 'email';
  }

  Future<void> saveActiveView(String view) async {
    try {
      final file = await _file(_activeViewFile);
      await file.writeAsString(view);
    } catch (_) {}
  }
}
