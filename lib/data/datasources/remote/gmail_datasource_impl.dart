import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/email.dart';
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
        final rawName = map['name'] as String? ?? id;
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
          isHidden: type == 'system' && id.startsWith('CATEGORY_'),
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

      return folders.map((f) {
        final count = childCountByParent[f.id] ?? 0;
        if (count == 0) return f;
        return EmailFolderModel(
          id: f.id,
          displayName: f.displayName,
          totalItemCount: f.totalItemCount,
          unreadItemCount: f.unreadItemCount,
          parentFolderId: f.parentFolderId,
          isHidden: f.isHidden,
          childFolderCount: count,
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
      final queryParams = <String, dynamic>{
        'maxResults': top,
        'labelIds': ?folderId,
      };

      final listResp = await _dio.get<Map<String, dynamic>>(
        '/users/me/messages',
        queryParameters: queryParams,
      );

      final data = listResp.data;
      if (data == null) return [];

      final messages = data['messages'] as List<dynamic>? ?? [];
      if (messages.isEmpty) return [];

      // Batch fetch message metadata.
      final metaFutures = messages.map((m) {
        final id = (m as Map<String, dynamic>)['id'] as String;
        return _fetchMessageMetadata(id);
      });

      return (await Future.wait(metaFutures)).whereType<EmailModel>().toList();
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  Future<EmailModel?> _fetchMessageMetadata(String id) async {
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

      // Large inline attachments (>2 MB) have only an attachmentId — no data
      // field in the payload. Fetch them concurrently and merge.
      final payload = resp.data!['payload'] as Map<String, dynamic>? ?? {};
      final pending = _extractAttachments(payload)
          .where((a) =>
              a.isInline &&
              a.contentId != null &&
              a.attachmentId.isNotEmpty &&
              a.inlineData == null)
          .toList();

      if (pending.isEmpty) return email;

      final fetched = await Future.wait(
        pending.map((a) => _fetchLargeInlineAttachment(id, a)),
      );

      final enriched = [
        ...email.inlineAttachments,
        ...fetched.whereType<InlineAttachment>(),
      ];

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
        meetingInvite: email.meetingInvite,
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
    final labelIds = (json['labelIds'] as List<dynamic>? ?? []).cast<String>();
    final isRead = !labelIds.contains('UNREAD');
    final snippet = json['snippet'] as String? ?? '';

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

    final subject = headerValue('Subject');
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
        meetingInvite = MeetingInvite(icsData: icsData);
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
  /// content. Returns null if no calendar part is found.
  String? _extractIcsData(Map<String, dynamic> payload) {
    final mimeType = (payload['mimeType'] as String? ?? '').toLowerCase();
    if (mimeType == 'text/calendar' || mimeType == 'application/ics') {
      final data = (payload['body'] as Map<String, dynamic>?)?['data'] as String?;
      if (data != null) {
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
  }) {
    throw UnimplementedError('sendEmail not yet supported for Gmail');
  }

  @override
  Future<void> replyToEmail({
    required String messageId,
    required String comment,
    bool replyAll = false,
  }) {
    throw UnimplementedError('replyToEmail not yet supported for Gmail');
  }

  @override
  Future<void> forwardEmail({
    required String messageId,
    required List<String> toAddresses,
    required String comment,
  }) {
    throw UnimplementedError('forwardEmail not yet supported for Gmail');
  }

  @override
  Future<void> moveEmail(String id, String destinationFolderId) {
    throw UnimplementedError('moveEmail not yet supported for Gmail');
  }

  @override
  Future<void> deleteEmail(String id) {
    throw UnimplementedError('deleteEmail not yet supported for Gmail');
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
