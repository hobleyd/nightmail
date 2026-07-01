import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/utils/html_entities.dart';
import '../../../core/utils/ics_parser.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/local_attachment.dart';
import '../../../domain/entities/email_attachment.dart';
import '../../../domain/entities/inline_attachment.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../infrastructure/http/gmail_http_client.dart';
import '../../models/email_address_model.dart';
import '../../models/email_folder_model.dart';
import '../../models/email_model.dart';
import 'email_remote_datasource.dart';

class GmailDatasourceImpl implements EmailRemoteDatasource {
  GmailDatasourceImpl({required GmailHttpClient client}) : _dio = client.dio;

  @visibleForTesting
  GmailDatasourceImpl.withDio(this._dio);

  final Dio _dio;
  String? _cachedUserEmail;

  @override
  Future<List<EmailFolderModel>> getMailFolders() async {
    try {
      final response =
          await _dio.get<Map<String, dynamic>>('/users/me/labels');
      final data = response.data;
      if (data == null) return [];

      final labels = data['labels'] as List<dynamic>? ?? [];

      // First pass: collect raw label data, skipping hidden system labels.
      final rawLabels = <Map<String, dynamic>>[];
      for (final label in labels) {
        final map = label as Map<String, dynamic>;
        final id = map['id'] as String;
        final type = map['type'] as String? ?? '';
        if (type == 'system' && _isHiddenSystemLabel(id)) continue;
        rawLabels.add(map);
      }

      // Build a map from label name → label id for hierarchy resolution.
      final nameToId = <String, String>{};
      for (final map in rawLabels) {
        final name = map['name'] as String? ?? '';
        if (name.isNotEmpty) nameToId[name] = map['id'] as String;
      }

      // Second pass: build folder models, expanding "/" into parent/child links.
      final folders = <EmailFolderModel>[];
      final virtualFolderIds = <String>{};

      for (final map in rawLabels) {
        final id = map['id'] as String;
        final type = map['type'] as String? ?? '';
        final rawName = _transformLabelName(map['name'] as String? ?? id);
        final parts = rawName.split('/');

        // For each intermediate path segment, create a virtual parent folder
        // if no real Gmail label exists with that path.
        for (int i = 1; i < parts.length; i++) {
          final ancestorPath = parts.sublist(0, i).join('/');
          if (nameToId.containsKey(ancestorPath)) continue;
          final virtualId = '__virtual__$ancestorPath';
          if (virtualFolderIds.contains(virtualId)) continue;
          virtualFolderIds.add(virtualId);
          final grandParentPath =
              i > 1 ? parts.sublist(0, i - 1).join('/') : null;
          final virtualParentId = grandParentPath == null
              ? null
              : nameToId[grandParentPath] ?? '__virtual__$grandParentPath';
          folders.add(EmailFolderModel(
            id: virtualId,
            displayName: parts[i - 1],
            totalItemCount: 0,
            unreadItemCount: 0,
            parentFolderId: virtualParentId,
            isHidden: false,
            childFolderCount: 0,
          ));
        }

        // Determine the parent id for this label.
        String? parentFolderId;
        if (parts.length > 1) {
          final parentPath = parts.sublist(0, parts.length - 1).join('/');
          parentFolderId =
              nameToId[parentPath] ?? '__virtual__$parentPath';
        }

        folders.add(EmailFolderModel(
          id: id,
          displayName: _labelDisplayName(parts.last),
          totalItemCount: 0,
          unreadItemCount: 0,
          parentFolderId: parentFolderId,
          isHidden: false,
          childFolderCount: 0,
        ));
      }

      // Fix up childFolderCount based on actual parent references.
      final childCountByParent = <String, int>{};
      for (final f in folders) {
        if (f.parentFolderId != null) {
          childCountByParent[f.parentFolderId!] =
              (childCountByParent[f.parentFolderId!] ?? 0) + 1;
        }
      }

      // The labels list endpoint omits message counts. Fetch them in parallel
      // for all real (non-virtual) labels so the poller and folder list are correct.
      final realIds = folders
          .where((f) => !f.id.startsWith('__virtual__'))
          .map((f) => f.id)
          .toList();
      final countMap = <String, (int, int)>{};
      await Future.wait(realIds.map((id) async {
        try {
          final resp =
              await _dio.get<Map<String, dynamic>>('/users/me/labels/$id');
          final d = resp.data;
          if (d == null) return;
          countMap[id] = (
            d['messagesUnread'] as int? ?? 0,
            d['messagesTotal'] as int? ?? 0,
          );
        } catch (_) {}
      }));

      return folders.map((f) {
        final childCount = childCountByParent[f.id] ?? 0;
        final counts = countMap[f.id];
        if (childCount == 0 && counts == null) return f;
        return EmailFolderModel(
          id: f.id,
          displayName: f.displayName,
          totalItemCount: counts?.$2 ?? f.totalItemCount,
          unreadItemCount: counts?.$1 ?? f.unreadItemCount,
          parentFolderId: f.parentFolderId,
          isHidden: f.isHidden,
          childFolderCount: childCount,
        );
      }).toList();
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<List<EmailFolderModel>> getChildFolders(String parentFolderId) async {
    // Gmail labels are flat — no children.
    return [];
  }

  @override
  Future<List<EmailModel>> getEmails({
    String? folderId,
    int top = 25,
    int skip = 0,
    String? filter,
    String orderBy = 'receivedDateTime desc',
  }) async {
    try {
      // Use the Threads API so that cross-folder messages are included.
      // labelIds filters *which threads* to show (threads that have at least
      // one message with that label), but every message in each thread is
      // returned regardless of which label it carries.
      final queryParams = <String, dynamic>{
        'maxResults': top,
        'labelIds': ?folderId,
      };

      final listResp = await _dio.get<Map<String, dynamic>>(
        '/users/me/threads',
        queryParameters: queryParams,
      );

      final data = listResp.data;
      if (data == null) return [];

      final threads = data['threads'] as List<dynamic>? ?? [];
      if (threads.isEmpty) return [];

      // Fetch all messages in each thread in parallel.
      // When viewing a normal folder (not Trash/Spam), exclude messages that
      // have been trashed or marked as spam — they belong to those folders and
      // must not be re-cached under the current folder (the cache primary key
      // is (emailId, accountId), so an insertOrReplace would move them here).
      final excludeLabels = (folderId == 'TRASH' || folderId == 'SPAM')
          ? const <String>{}
          : const {'TRASH', 'SPAM'};

      final threadFutures = threads.map((t) {
        final id = (t as Map<String, dynamic>)['id'] as String;
        return _fetchThreadMessages(id, excludeLabels: excludeLabels);
      });

      return (await Future.wait(threadFutures)).expand((msgs) => msgs).toList();
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  Future<List<EmailModel>> _fetchThreadMessages(
    String threadId, {
    Set<String> excludeLabels = const {},
  }) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/users/me/threads/$threadId',
        queryParameters: {
          'format': 'metadata',
          'metadataHeaders': ['From', 'To', 'Cc', 'Subject', 'Date'],
        },
      );
      if (resp.data == null) return [];
      var messages = (resp.data!['messages'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      if (excludeLabels.isNotEmpty) {
        messages = messages.where((m) {
          final labels =
              (m['labelIds'] as List<dynamic>? ?? []).cast<String>();
          return !labels.any(excludeLabels.contains);
        }).toList();
      }
      return messages.map((m) => _parseMessage(m, fullBody: false)).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<EmailModel>> searchEmails({
    String? folderId,
    required String query,
    int top = 50,
  }) async {
    // Gmail's q parameter natively supports from:, to:, subject:, has:attachment.
    try {
      final listResp = await _dio.get<Map<String, dynamic>>(
        '/users/me/messages',
        queryParameters: {'maxResults': top, 'q': query},
      );

      final data = listResp.data;
      if (data == null) return [];

      final messages = data['messages'] as List<dynamic>? ?? [];
      if (messages.isEmpty) return [];

      final futures = messages.map((m) async {
        final id = (m as Map<String, dynamic>)['id'] as String;
        try {
          final resp = await _dio.get<Map<String, dynamic>>(
            '/users/me/messages/$id',
            queryParameters: {
              'format': 'metadata',
              'metadataHeaders': ['From', 'To', 'Cc', 'Subject', 'Date'],
            },
          );
          if (resp.data == null) return null;
          return _parseMessage(resp.data!, fullBody: false);
        } catch (_) {
          return null;
        }
      });

      final results = await Future.wait(futures);
      return results.whereType<EmailModel>().toList();
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<EmailModel> getEmail(String id) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/users/me/messages/$id',
        queryParameters: {'format': 'full'},
      );
      if (resp.data == null) {
        throw ServerException(message: 'Empty response for message $id');
      }

      final email = _parseMessage(resp.data!, fullBody: true);

      final payload = resp.data!['payload'] as Map<String, dynamic>? ?? {};

      // If no ICS was inlined in the payload, check for a calendar attachment
      // stored separately — Gmail omits body.data for some parts even when
      // the content is small, requiring a dedicated attachment fetch.
      MeetingInvite? meetingInvite = email.meetingInvite;
      if (meetingInvite == null) {
        final icsId = _findIcsAttachmentId(payload);
        if (icsId != null) {
          try {
            final ar = await _dio.get<Map<String, dynamic>>(
              '/users/me/messages/$id/attachments/$icsId',
            );
            final raw = ar.data?['data'] as String?;
            if (raw != null && raw.isNotEmpty) {
              final icsStr = utf8.decode(base64Url.decode(_padBase64(raw)));
              final type = _icsMethod(icsStr) == 'CANCEL'
                  ? MeetingEmailType.cancellation
                  : MeetingEmailType.invitation;
              try {
                final event = IcsParser.parse(icsStr);
                meetingInvite = MeetingInvite(
                  icsData: icsStr,
                  type: type,
                  meetingStart: event.start,
                  meetingEnd: event.end,
                  location: event.location,
                  isAllDay: event.isAllDay,
                );
              } catch (_) {
                meetingInvite = MeetingInvite(icsData: icsStr, type: type);
              }
            }
          } catch (_) {}
        }
      }

      // Large inline attachments (>2 MB) have only an attachmentId — no data
      // field in the payload. Fetch them concurrently and merge.
      final pending = _extractAttachments(payload)
          .where((a) =>
              a.isInline &&
              a.contentId != null &&
              a.attachmentId.isNotEmpty &&
              a.inlineData == null)
          .toList();

      if (pending.isEmpty && meetingInvite == email.meetingInvite) return email;

      List<InlineAttachment> enriched = email.inlineAttachments;
      if (pending.isNotEmpty) {
        final fetched = await Future.wait(
          pending.map((a) => _fetchLargeInlineAttachment(id, a)),
        );
        enriched = [
          ...email.inlineAttachments,
          ...fetched.whereType<InlineAttachment>(),
        ];
      }

      return EmailModel(
        id: email.id,
        subject: email.subject,
        from: EmailAddressModel.fromEntity(email.from),
        toRecipients:
            email.toRecipients.map(EmailAddressModel.fromEntity).toList(),
        ccRecipients:
            email.ccRecipients.map(EmailAddressModel.fromEntity).toList(),
        bodyPreview: email.bodyPreview,
        body: email.body,
        bodyType: email.bodyType,
        isRead: email.isRead,
        receivedDateTime: email.receivedDateTime,
        importance: email.importance,
        parentFolderId: email.parentFolderId,
        hasAttachments: email.hasAttachments,
        attachments: email.attachments,
        inlineAttachments: enriched,
        meetingInvite: meetingInvite,
      );
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  Future<InlineAttachment?> _fetchLargeInlineAttachment(
      String messageId, _GmailAttachment a) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/users/me/messages/$messageId/attachments/${a.attachmentId}',
      );
      final rawData = response.data?['data'] as String?;
      if (rawData == null || rawData.isEmpty) return null;
      return InlineAttachment(
        contentId: a.contentId!,
        contentType: a.contentType,
        contentBytes: base64Url.decode(_padBase64(rawData)),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<EmailModel> updateEmailReadStatus({
    required String id,
    required bool isRead,
  }) async {
    try {
      final body = isRead
          ? {'removeLabelIds': ['UNREAD']}
          : {'addLabelIds': ['UNREAD']};

      await _dio.post<Map<String, dynamic>>(
        '/users/me/messages/$id/modify',
        data: body,
      );

      // Re-fetch the message to return updated state.
      return getEmail(id);
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Parsing helpers
  // ---------------------------------------------------------------------------

  EmailModel _parseMessage(Map<String, dynamic> json, {required bool fullBody}) {
    final id = json['id'] as String;
    final threadId = json['threadId'] as String?;
    final labelIds = (json['labelIds'] as List<dynamic>? ?? []).cast<String>();
    final isRead = !labelIds.contains('UNREAD');
    final snippet = decodeHtmlEntities(json['snippet'] as String? ?? '');

    final payload = json['payload'] as Map<String, dynamic>? ?? {};
    final headers = (payload['headers'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    String headerValue(String name) {
      return headers
          .firstWhere(
            (h) => (h['name'] as String).toLowerCase() == name.toLowerCase(),
            orElse: () => {'value': ''},
          )['value'] as String;
    }

    final subject = decodeHtmlEntities(headerValue('Subject'));
    final fromStr = headerValue('From');
    final toStr = headerValue('To');
    final ccStr = headerValue('Cc');
    final dateStr = headerValue('Date');

    DateTime receivedAt;
    try {
      final internalDate = json['internalDate'] as String?;
      if (internalDate != null) {
        receivedAt = DateTime.fromMillisecondsSinceEpoch(
          int.parse(internalDate),
          isUtc: true,
        );
      } else {
        receivedAt = _parseRfc2822Date(dateStr);
      }
    } catch (_) {
      receivedAt = DateTime.now().toUtc();
    }

    String body = '';
    EmailBodyType bodyType = EmailBodyType.text;

    MeetingInvite? meetingInvite;
    List<EmailAttachment> attachments = const [];
    List<InlineAttachment> inlineAttachments = const [];

    if (fullBody) {
      final (extractedBody, extractedType) = _extractBody(payload);
      body = extractedBody;
      bodyType = extractedType;
      final icsData = _extractIcsData(payload);
      if (icsData != null) {
        final type = _icsMethod(icsData) == 'CANCEL'
            ? MeetingEmailType.cancellation
            : MeetingEmailType.invitation;
        try {
          final event = IcsParser.parse(icsData);
          meetingInvite = MeetingInvite(
            icsData: icsData,
            type: type,
            meetingStart: event.start,
            meetingEnd: event.end,
            location: event.location,
            isAllDay: event.isAllDay,
          );
        } catch (_) {
          meetingInvite = MeetingInvite(icsData: icsData, type: type);
        }
      }

      final parsed = _extractAttachments(payload);
      attachments = parsed
          .where((a) => !a.isInline)
          .map((a) => EmailAttachment(
                id: a.attachmentId,
                name: a.name,
                contentType: a.contentType,
                size: a.size,
              ))
          .toList();
      inlineAttachments = parsed
          .where((a) => a.isInline && a.contentId != null && a.inlineData != null)
          .map((a) {
            try {
              return InlineAttachment(
                contentId: a.contentId!,
                contentType: a.contentType,
                contentBytes: base64Url.decode(_padBase64(a.inlineData!)),
              );
            } catch (_) {
              return null;
            }
          })
          .whereType<InlineAttachment>()
          .toList();
    }

    final parentFolderId = labelIds.contains('INBOX')
        ? 'INBOX'
        : labelIds.where((l) => !_isSystemLabel(l)).firstOrNull;

    return EmailModel(
      id: id,
      conversationId: threadId,
      subject: subject.isEmpty ? '(No Subject)' : subject,
      from: _parseAddress(fromStr),
      toRecipients: _parseAddressList(toStr),
      ccRecipients: _parseAddressList(ccStr),
      bodyPreview: snippet,
      body: body,
      bodyType: bodyType,
      isRead: isRead,
      receivedDateTime: receivedAt,
      importance: EmailImportance.normal,
      parentFolderId: parentFolderId,
      hasAttachments: _detectAttachments(payload),
      attachments: attachments,
      inlineAttachments: inlineAttachments,
      meetingInvite: meetingInvite,
    );
  }

  (String, EmailBodyType) _extractBody(Map<String, dynamic> payload) {
    final mimeType = payload['mimeType'] as String? ?? '';

    if (mimeType == 'text/html' || mimeType == 'text/plain') {
      final data = (payload['body'] as Map<String, dynamic>?)?['data'] as String?;
      if (data != null) {
        final decoded = utf8.decode(base64Url.decode(_padBase64(data)));
        return (decoded, mimeType == 'text/html' ? EmailBodyType.html : EmailBodyType.text);
      }
    }

    // Multipart: prefer HTML part.
    final parts = (payload['parts'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    String? htmlBody;
    String? textBody;

    void scanParts(List<Map<String, dynamic>> partList) {
      for (final part in partList) {
        final mt = part['mimeType'] as String? ?? '';
        if (mt == 'text/html') {
          final data = (part['body'] as Map<String, dynamic>?)?['data'] as String?;
          if (data != null) {
            htmlBody = utf8.decode(base64Url.decode(_padBase64(data)));
          }
        } else if (mt == 'text/plain' && htmlBody == null) {
          final data = (part['body'] as Map<String, dynamic>?)?['data'] as String?;
          if (data != null) {
            textBody = utf8.decode(base64Url.decode(_padBase64(data)));
          }
        } else if (mt.startsWith('multipart/')) {
          final nested = (part['parts'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          scanParts(nested);
        }
      }
    }

    scanParts(parts);

    if (htmlBody != null) return (htmlBody!, EmailBodyType.html);
    if (textBody != null) return (textBody!, EmailBodyType.text);
    return ('', EmailBodyType.text);
  }

  /// Recursively scan MIME parts for a text/calendar part and return its decoded
  /// content. Returns null if no calendar part is found or if the content is
  /// stored as a separate attachment (see [_findIcsAttachmentId]).
  /// Returns the METHOD value (e.g. 'REQUEST', 'CANCEL') from an iCalendar string.
  String? _icsMethod(String icsData) {
    for (final rawLine in icsData.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.toUpperCase().startsWith('METHOD:')) {
        return line.substring('METHOD:'.length).trim().toUpperCase();
      }
    }
    return null;
  }

  String? _extractIcsData(Map<String, dynamic> payload) {
    final mimeType = (payload['mimeType'] as String? ?? '').toLowerCase();
    final filename = (payload['filename'] as String? ?? '').toLowerCase();
    // Match on MIME type or .ics filename — some senders use application/octet-stream.
    if (mimeType == 'text/calendar' || mimeType == 'application/ics' ||
        filename.endsWith('.ics')) {
      final data = (payload['body'] as Map<String, dynamic>?)?['data'] as String?;
      if (data != null && data.isNotEmpty) {
        return utf8.decode(base64Url.decode(_padBase64(data)));
      }
    }
    final parts = (payload['parts'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    for (final part in parts) {
      final result = _extractIcsData(part);
      if (result != null) return result;
    }
    return null;
  }

  /// Recursively scan MIME parts for a calendar attachment whose content was
  /// not inlined (body.data is absent). Returns the Gmail attachment ID so the
  /// caller can fetch it separately. Returns null if the ICS is already inlined.
  String? _findIcsAttachmentId(Map<String, dynamic> payload) {
    final mimeType = (payload['mimeType'] as String? ?? '').toLowerCase();
    final filename = (payload['filename'] as String? ?? '').toLowerCase();
    if (mimeType == 'text/calendar' || mimeType == 'application/ics' ||
        filename.endsWith('.ics')) {
      final body = payload['body'] as Map<String, dynamic>?;
      final data = body?['data'] as String?;
      if (data != null && data.isNotEmpty) return null; // already inlined
      final attachmentId = body?['attachmentId'] as String?;
      if (attachmentId != null && attachmentId.isNotEmpty) return attachmentId;
    }
    final parts = (payload['parts'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    for (final part in parts) {
      final result = _findIcsAttachmentId(part);
      if (result != null) return result;
    }
    return null;
  }

  bool _detectAttachments(Map<String, dynamic> payload) {
    final filename = payload['filename'] as String? ?? '';
    if (filename.isNotEmpty) return true;

    final parts = (payload['parts'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    for (final part in parts) {
      if (_detectAttachments(part)) return true;
    }
    return false;
  }

  List<_GmailAttachment> _extractAttachments(Map<String, dynamic> payload) {
    final results = <_GmailAttachment>[];
    _collectAttachmentParts(payload, results);
    return results;
  }

  void _collectAttachmentParts(
      Map<String, dynamic> part, List<_GmailAttachment> out) {
    final filename = (part['filename'] as String? ?? '').trim();

    if (filename.isNotEmpty) {
      final mimeType = part['mimeType'] as String? ?? 'application/octet-stream';
      final body = part['body'] as Map<String, dynamic>? ?? {};
      final attachmentId = body['attachmentId'] as String? ?? '';
      final inlineData = body['data'] as String?;
      final size = body['size'] as int? ?? 0;
      final headers = (part['headers'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();

      String? contentId;
      bool hasAttachmentDisposition = false;
      for (final h in headers) {
        final name = (h['name'] as String? ?? '').toLowerCase();
        final value = h['value'] as String? ?? '';
        if (name == 'content-id' && value.isNotEmpty) contentId = value.trim();
        if (name == 'content-disposition' &&
            value.toLowerCase().startsWith('attachment')) {
          hasAttachmentDisposition = true;
        }
      }

      final isInline = contentId != null && !hasAttachmentDisposition;
      out.add(_GmailAttachment(
        attachmentId: attachmentId,
        name: filename,
        contentType: mimeType,
        size: size,
        isInline: isInline,
        contentId: isInline ? contentId : null,
        inlineData: inlineData,
      ));
    }

    final subParts = (part['parts'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    for (final sub in subParts) {
      _collectAttachmentParts(sub, out);
    }
  }

  String _padBase64(String s) {
    final padding = (4 - s.length % 4) % 4;
    return s + ('=' * padding);
  }

  EmailAddressModel _parseAddress(String raw) {
    if (raw.isEmpty) return const EmailAddressModel(address: '', name: '');
    // Handles: "Display Name <email>", "<email>", and bare "email"
    final match = RegExp(r'^(.*?)\s*<([^>]+)>\s*$').firstMatch(raw.trim());
    if (match != null) {
      return EmailAddressModel(
        name: (match.group(1) ?? '').replaceAll('"', '').trim(),
        address: match.group(2)?.trim() ?? '',
      );
    }
    return EmailAddressModel(address: raw.trim(), name: '');
  }

  List<EmailAddressModel> _parseAddressList(String raw) {
    if (raw.isEmpty) return [];
    return raw.split(',').map((s) => _parseAddress(s.trim())).toList();
  }

  DateTime _parseRfc2822Date(String date) {
    // Attempt parsing — fallback to now.
    try {
      return DateTime.parse(date);
    } catch (_) {
      return DateTime.now().toUtc();
    }
  }

  bool _isSystemLabel(String id) {
    const system = {
      'INBOX', 'SENT', 'DRAFT', 'TRASH', 'SPAM', 'STARRED', 'IMPORTANT',
      'UNREAD', 'CHAT', 'CATEGORY_PERSONAL', 'CATEGORY_SOCIAL',
      'CATEGORY_PROMOTIONS', 'CATEGORY_UPDATES', 'CATEGORY_FORUMS',
    };
    return system.contains(id);
  }

  bool _isHiddenSystemLabel(String id) {
    const hidden = {'CHAT', 'STARRED', 'IMPORTANT', 'UNREAD'};
    return hidden.contains(id);
  }

  String _transformLabelName(String name) {
    if (!name.startsWith('CATEGORY_')) return name;
    final suffix = name.substring('CATEGORY_'.length);
    final titled = suffix[0].toUpperCase() + suffix.substring(1).toLowerCase();
    return 'Category/$titled';
  }

  String _labelDisplayName(String name) {
    return switch (name) {
      'INBOX' => 'Inbox',
      'SENT' => 'Sent',
      'DRAFT' => 'Drafts',
      'TRASH' => 'Trash',
      'SPAM' => 'Spam',
      _ => name,
    };
  }

  @override
  Future<void> sendEmail({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final fromEmail = await _getUserEmail();
      final builder = MessageBuilder()
        ..from = [MailAddress(null, fromEmail)]
        ..to = toAddresses.map((a) => MailAddress(null, a)).toList()
        ..cc = ccAddresses.map((a) => MailAddress(null, a)).toList()
        ..subject = subject;
      if (bodyType == EmailBodyType.html) {
        builder.addTextHtml(body);
      } else {
        builder.addTextPlain(body);
      }
      await _addAttachmentsToBuilder(builder, newAttachments);
      final mime = builder.buildMimeMessage();
      final encoded = base64Url
          .encode(utf8.encode(mime.renderMessage()))
          .replaceAll('=', '');
      await _dio.post<void>('/users/me/messages/send', data: {'raw': encoded});
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<void> replyToEmail({
    required String messageId,
    required String comment,
    bool replyAll = false,
    List<String> toAddresses = const [],
    List<String> ccAddresses = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final rawResp = await _dio.get<Map<String, dynamic>>(
        '/users/me/messages/$messageId',
        queryParameters: {'format': 'raw'},
      );
      if (rawResp.data == null) {
        throw const ServerException(message: 'Message not found');
      }
      final rawBase64 = rawResp.data!['raw'] as String?;
      if (rawBase64 == null) {
        throw const ServerException(message: 'No raw data in response');
      }
      final threadId = rawResp.data!['threadId'] as String?;

      final rawBytes = base64Url.decode(_padBase64(rawBase64));
      final original = MimeMessage.parseFromData(rawBytes);

      final fromEmail = await _getUserEmail();
      final builder = MessageBuilder.prepareReplyToMessage(
        original,
        MailAddress(null, fromEmail),
        replyAll: replyAll,
      );
      if (toAddresses.isNotEmpty) {
        builder.to = toAddresses.map((a) => MailAddress(null, a)).toList();
      }
      if (ccAddresses.isNotEmpty) {
        builder.cc = ccAddresses.map((a) => MailAddress(null, a)).toList();
      }
      if (bodyType == EmailBodyType.html) {
        builder.addTextHtml(comment);
      } else {
        builder.addTextPlain(comment);
      }
      await _addAttachmentsToBuilder(builder, newAttachments);

      final mime = builder.buildMimeMessage();
      final encoded = base64Url
          .encode(utf8.encode(mime.renderMessage()))
          .replaceAll('=', '');

      await _dio.post<void>(
        '/users/me/messages/send',
        data: {
          'raw': encoded,
          if (threadId != null) 'threadId': threadId,
        },
      );
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<void> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String comment,
    List<String> excludedAttachmentIds = const [],
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/users/me/messages/$messageId',
        queryParameters: {'format': 'full'},
      );
      if (resp.data == null) throw const ServerException(message: 'Message not found');

      final threadId = resp.data!['threadId'] as String?;
      final payload = resp.data!['payload'] as Map<String, dynamic>? ?? {};
      final hdrs = (payload['headers'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      String hdr(String name) => hdrs
          .firstWhere(
            (h) => (h['name'] as String).toLowerCase() == name.toLowerCase(),
            orElse: () => {'value': ''},
          )['value'] as String;

      final originalSubject = hdr('Subject');

      final fromEmail = await _getUserEmail();
      final subject = originalSubject.startsWith('Fwd:')
          ? originalSubject
          : 'Fwd: $originalSubject';

      final builder = MessageBuilder()
        ..to = toAddresses.map((e) => MailAddress(null, e)).toList()
        ..subject = subject;

      if (ccAddresses.isNotEmpty) {
        builder.cc = ccAddresses.map((e) => MailAddress(null, e)).toList();
      }

      if (fromEmail.isNotEmpty) {
        builder.from = [MailAddress(null, fromEmail)];
      }

      // Compose body already contains the full forwarded content the user can edit;
      // send it as-is rather than re-appending the original.
      if (bodyType == EmailBodyType.html) {
        builder.addTextHtml(comment);
      } else {
        builder.addTextPlain(comment);
      }

      final allAttachments = _extractAttachments(payload);
      for (final att in allAttachments) {
        if (att.isInline || att.attachmentId.isEmpty) continue;
        if (excludedAttachmentIds.contains(att.attachmentId)) continue;
        try {
          final bytes = await downloadAttachment(messageId, att.attachmentId);
          builder.addBinary(
            bytes,
            MediaType.fromText(
              att.contentType.isNotEmpty
                  ? att.contentType
                  : 'application/octet-stream',
            ),
            filename: att.name,
          );
        } catch (_) {
          // skip attachments that fail to download
        }
      }

      await _addAttachmentsToBuilder(builder, newAttachments);

      final mime = builder.buildMimeMessage();
      final rawMime = mime.renderMessage();
      final rawBase64 =
          base64Url.encode(utf8.encode(rawMime)).replaceAll('=', '');

      await _dio.post<void>(
        '/users/me/messages/send',
        data: {
          'raw': rawBase64,
          if (threadId != null) 'threadId': threadId,
        },
      );
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  Future<void> _addAttachmentsToBuilder(
      MessageBuilder builder, List<LocalAttachment> attachments) async {
    for (final att in attachments) {
      if (att.isInline && att.contentId != null) {
        final part = builder.addBinary(
          att.bytes,
          MediaType.fromText(att.mimeType),
          filename: att.name,
          disposition: ContentDispositionHeader.from(ContentDisposition.inline),
        );
        part.setHeader('Content-Id', '<${att.contentId}>');
      } else {
        builder.addBinary(
          att.bytes,
          MediaType.fromText(att.mimeType),
          filename: att.name,
        );
      }
    }
  }

  Future<String> _getUserEmail() async {
    if (_cachedUserEmail != null) return _cachedUserEmail!;
    try {
      final resp =
          await _dio.get<Map<String, dynamic>>('/users/me/profile');
      _cachedUserEmail = resp.data?['emailAddress'] as String? ?? '';
      return _cachedUserEmail!;
    } catch (_) {
      return '';
    }
  }


  @override
  Future<void> moveEmail(String id, String destinationFolderId) async {
    // Fetch current labels so we know what to remove. Using metadata format
    // with a field mask avoids downloading the full message body.
    final metaResp = await _dio.get<Map<String, dynamic>>(
      '/users/me/messages/$id',
      queryParameters: {
        'format': 'metadata',
        'fields': 'labelIds',
      },
    );
    final currentLabels =
        (metaResp.data?['labelIds'] as List<dynamic>? ?? []).cast<String>();

    // Labels that act as "folders" — either user-created (Label_xxx) or the
    // small set of system labels that represent a mailbox location.
    // SENT cannot be removed via the Gmail API (returns 400) — exclude it so
    // the entire modify call doesn't fail for messages that carry that label.
    const folderLike = {'INBOX', 'SPAM', 'TRASH'};
    final toRemove = currentLabels
        .where((l) => l != destinationFolderId)
        .where((l) => folderLike.contains(l) || l.startsWith('Label_'))
        .toList();

    await _dio.post<void>(
      '/users/me/messages/$id/modify',
      data: {
        'addLabelIds': [destinationFolderId],
        if (toRemove.isNotEmpty) 'removeLabelIds': toRemove,
      },
    );
  }

  @override
  @override
  Future<void> reportJunk(String id) async {
    await _dio.post<void>(
      '/users/me/messages/$id/modify',
      data: {
        'addLabelIds': ['SPAM'],
        'removeLabelIds': ['INBOX'],
      },
    );
  }

  Future<void> deleteEmail(String id) async {
    await _dio.post<void>('/users/me/messages/$id/trash');
  }

  @override
  Future<void> emptyFolder(String folderId, {bool permanentDelete = false}) {
    throw UnimplementedError('emptyFolder not yet supported for Gmail');
  }

  @override
  Future<Uint8List> downloadAttachment(
      String messageId, String attachmentId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/users/me/messages/$messageId/attachments/$attachmentId',
      );
      final data = response.data;
      if (data == null) {
        throw const ServerException(message: 'Empty response from server');
      }
      final rawData = data['data'] as String?;
      if (rawData == null || rawData.isEmpty) {
        throw const ServerException(message: 'No attachment data in response');
      }
      return base64Url.decode(_padBase64(rawData));
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<Uint8List> getRawEmailBytes(String id) {
    throw UnimplementedError('getRawEmailBytes not yet supported for Gmail');
  }

  @override
  Future<void> createFolder({
    required String parentFolderId,
    required String displayName,
  }) async {
    try {
      // Fetch the parent label's full name so we can prefix the new label.
      final parentResp = await _dio.get<Map<String, dynamic>>(
        '/users/me/labels/$parentFolderId',
      );
      final parentName = parentResp.data?['name'] as String? ?? '';
      final labelName =
          parentName.isEmpty ? displayName : '$parentName/$displayName';
      await _dio.post<void>(
        '/users/me/labels',
        data: {'name': labelName},
      );
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<void> renameFolder({
    required String folderId,
    required String newDisplayName,
  }) async {
    try {
      // Fetch the current label to extract the parent prefix.
      final resp = await _dio.get<Map<String, dynamic>>(
        '/users/me/labels/$folderId',
      );
      final currentName = resp.data?['name'] as String? ?? '';
      final lastSlash = currentName.lastIndexOf('/');
      final newName = lastSlash >= 0
          ? '${currentName.substring(0, lastSlash)}/$newDisplayName'
          : newDisplayName;
      await _dio.patch<void>(
        '/users/me/labels/$folderId',
        data: {'name': newName},
      );
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<String> createServerDraft({
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final fromEmail = await _getUserEmail();
      final encoded = await compute(_buildDraftRawBase64, _DraftMimeParams(
        fromAddress: fromEmail,
        toAddresses: toAddresses,
        ccAddresses: ccAddresses,
        subject: subject,
        body: body,
        isHtml: bodyType == EmailBodyType.html,
        attachments: newAttachments,
      ));
      final resp = await _dio.post<Map<String, dynamic>>(
        '/users/me/drafts',
        data: {'message': {'raw': encoded}},
      );
      final id = resp.data?['id'] as String?;
      if (id == null) throw const ServerException(message: 'No draft ID in response');
      return id;
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<String> updateServerDraft({
    required String draftId,
    required List<String> toAddresses,
    List<String> ccAddresses = const [],
    required String subject,
    required String body,
    EmailBodyType bodyType = EmailBodyType.text,
    List<LocalAttachment> newAttachments = const [],
  }) async {
    try {
      final fromEmail = await _getUserEmail();
      final encoded = await compute(_buildDraftRawBase64, _DraftMimeParams(
        fromAddress: fromEmail,
        toAddresses: toAddresses,
        ccAddresses: ccAddresses,
        subject: subject,
        body: body,
        isHtml: bodyType == EmailBodyType.html,
        attachments: newAttachments,
      ));

      // The Drafts folder email list returns message IDs, but the drafts
      // endpoint requires the draft ID (r…). Try the ID as-is; if Gmail
      // returns 404, look up the real draft ID from the drafts list.
      String resolvedId = draftId;
      try {
        await _dio.put<dynamic>(
          '/users/me/drafts/$draftId',
          data: {'message': {'raw': encoded}},
        );
        return draftId;
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
        resolvedId = await _findDraftIdByMessageId(draftId) ?? draftId;
      }

      if (resolvedId != draftId) {
        await _dio.put<dynamic>(
          '/users/me/drafts/$resolvedId',
          data: {'message': {'raw': encoded}},
        );
        return resolvedId;
      }

      // Draft not found at all — create a new one as fallback.
      final resp = await _dio.post<Map<String, dynamic>>(
        '/users/me/drafts',
        data: {'message': {'raw': encoded}},
      );
      final id = resp.data?['id'] as String?;
      if (id == null) throw const ServerException(message: 'No draft ID in response');
      return id;
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  // Fetches up to 200 drafts and returns the draft ID whose embedded message
  // ID matches [messageId], or null if not found.
  Future<String?> _findDraftIdByMessageId(String messageId) async {
    final resp = await _dio.get<Map<String, dynamic>>(
      '/users/me/drafts',
      queryParameters: {'maxResults': 200},
    );
    final drafts = resp.data?['drafts'] as List<dynamic>? ?? [];
    for (final d in drafts) {
      final dMap = d as Map<String, dynamic>;
      if ((dMap['message'] as Map<String, dynamic>?)?['id'] == messageId) {
        return dMap['id'] as String;
      }
    }
    return null;
  }

  @override
  Future<void> deleteServerDraft({required String draftId}) async {
    try {
      await _dio.delete<void>('/users/me/drafts/$draftId');
    } on DioException catch (e) {
      // If the ID is a message ID rather than a draft ID, look up the real
      // draft ID and retry once. This happens when a draft is opened from the
      // Drafts folder (where we only have the message ID) and sent before the
      // first auto-save, which would have normalised the ID.
      if (e.response?.statusCode == 404) {
        final resolvedId = await _findDraftIdByMessageId(draftId);
        if (resolvedId != null) {
          try {
            await _dio.delete<void>('/users/me/drafts/$resolvedId');
            return;
          } on DioException catch (e2) {
            throw _mapException(e2);
          }
        }
      }
      throw _mapException(e);
    }
  }

  Exception _mapException(DioException e) {
    final statusCode = e.response?.statusCode;
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return NetworkException(message: e.message ?? 'Network error');
    }
    if (statusCode == 401) {
      return const AuthException(message: 'Authentication required');
    }
    return ServerException(
        message: e.message ?? 'Server error ($statusCode)',
        statusCode: statusCode);
  }
}

class _GmailAttachment {
  _GmailAttachment({
    required this.attachmentId,
    required this.name,
    required this.contentType,
    required this.size,
    required this.isInline,
    this.contentId,
    this.inlineData,
  });

  final String attachmentId;
  final String name;
  final String contentType;
  final int size;
  final bool isInline;
  final String? contentId;
  final String? inlineData;
}

/// Inputs for [_buildDraftRawBase64]. Kept as plain, isolate-transferable
/// data (no [MessageBuilder]/[MimeMessage] instances) since [compute] runs
/// the builder on a background isolate.
class _DraftMimeParams {
  const _DraftMimeParams({
    required this.fromAddress,
    required this.toAddresses,
    required this.ccAddresses,
    required this.subject,
    required this.body,
    required this.isHtml,
    required this.attachments,
  });

  final String fromAddress;
  final List<String> toAddresses;
  final List<String> ccAddresses;
  final String subject;
  final String body;
  final bool isHtml;
  final List<LocalAttachment> attachments;
}

/// Builds, renders and base64url-encodes a draft MIME message off the main
/// isolate.
///
/// Encoding a large HTML body (a long quoted reply can be hundreds of KB)
/// via [MessageBuilder.buildMimeMessage], [MimeMessage.renderMessage] and
/// then base64 is synchronous CPU work; running it on the main isolate
/// froze the compose UI every time the draft autosave timer fired.
/// [compute] moves it to a worker isolate so only the network request
/// touches the main isolate.
String _buildDraftRawBase64(_DraftMimeParams p) {
  final builder = MessageBuilder()
    ..from = [MailAddress(null, p.fromAddress)]
    ..to = p.toAddresses.map((a) => MailAddress(null, a)).toList()
    ..cc = p.ccAddresses.map((a) => MailAddress(null, a)).toList()
    ..subject = p.subject;
  if (p.isHtml) {
    builder.addTextHtml(p.body);
  } else {
    builder.addTextPlain(p.body);
  }
  for (final att in p.attachments) {
    if (att.isInline && att.contentId != null) {
      final part = builder.addBinary(
        att.bytes,
        MediaType.fromText(att.mimeType),
        filename: att.name,
        disposition: ContentDispositionHeader.from(ContentDisposition.inline),
      );
      part.setHeader('Content-Id', '<${att.contentId}>');
    } else {
      builder.addBinary(
        att.bytes,
        MediaType.fromText(att.mimeType),
        filename: att.name,
      );
    }
  }
  final mime = builder.buildMimeMessage();
  return base64Url.encode(utf8.encode(mime.renderMessage())).replaceAll('=', '');
}
