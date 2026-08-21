import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/utils/special_folder_kind.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/local_attachment.dart';
import '../../../domain/entities/inline_attachment.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../infrastructure/http/gmail_http_client.dart';
import '../../models/email_address_model.dart';
import '../../models/email_folder_model.dart';
import '../../models/email_model.dart';
import '../../models/mail_delta_result.dart';
import 'contact_bulk_parser.dart' show googleNextPageToken;
import 'email_remote_datasource.dart';
import 'gmail_message_parser.dart';
import 'mail_delta_datasource.dart';

class GmailDatasourceImpl implements EmailRemoteDatasource, MailDeltaDatasource {
  GmailDatasourceImpl({required GmailHttpClient client, this.displayName = ''})
      : _dio = client.dio;

  @visibleForTesting
  GmailDatasourceImpl.withDio(this._dio, {this.displayName = ''});

  final Dio _dio;
  final String displayName;
  String? _cachedUserEmail;

  /// Stores the Gmail API nextPageToken per label/folder ID.
  /// Cleared on skip==0 (new list load); used on skip>0 (load-more).
  final Map<String?, String> _pageTokens = {};

  /// `(unread, total)` as each label last actually reported it.
  ///
  /// Counts come from one request per label, so a single transient failure in
  /// that burst must not be reported as a count of 0: the badge clears, the
  /// poller reads the drop as a change and recaches the folder, then overwrites
  /// its baseline with the zero — so the true count is never noticed again.
  /// A folder whose request failed keeps its last known count instead.
  final Map<String, (int, int)> _labelCounts = {};

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
        if (type == 'system' && isHiddenGmailSystemLabel(id)) continue;
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

      // The labels list endpoint omits message counts. Fetch them for all real
      // (non-virtual) labels so the poller and folder list are correct —
      // concurrently, but a chunk at a time (see [_labelCountConcurrency]).
      final realIds = folders
          .where((f) => !f.id.startsWith('__virtual__'))
          .map((f) => f.id)
          .toList();
      for (var i = 0; i < realIds.length; i += _labelCountConcurrency) {
        final chunk = realIds.sublist(
            i, (i + _labelCountConcurrency).clamp(0, realIds.length));
        await Future.wait(chunk.map(_fetchLabelCount));
      }

      return folders.map((f) {
        final childCount = childCountByParent[f.id] ?? 0;
        final counts = _labelCounts[f.id];
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

  /// Label detail requests in flight at once while refreshing counts.
  ///
  /// The labels *list* carries no counts, so every label costs a request of its
  /// own. Firing all of them at once is enough for Gmail to close connections
  /// mid-header on a mailbox with a few dozen labels ("Connection closed before
  /// full header was received"), which loses the counts this is here to fetch —
  /// and every folder-list load pays it again.
  static const _labelCountConcurrency = 8;

  /// Thread fetches in flight at once while expanding a folder page.
  ///
  /// Gmail has no multi-thread get, so the expansion costs one request per
  /// thread and the only lever is how many go out together. Same ceiling as
  /// [_labelCountConcurrency]: past it Gmail starts closing connections
  /// mid-header and throttling, and each 429 buys a second or more of
  /// `RetryInterceptor` backoff — which is slower than the queue it replaced.
  static const _threadFetchConcurrency = 8;

  /// Reads one label's message counts into [_labelCounts]. Never throws: a label
  /// that could not be counted keeps its last known figures rather than failing
  /// the whole folder listing.
  Future<void> _fetchLabelCount(String id) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>('/users/me/labels/$id');
      final d = resp.data;
      if (d == null) return;
      _labelCounts[id] = (
        d['messagesUnread'] as int? ?? 0,
        d['messagesTotal'] as int? ?? 0,
      );
    } catch (e) {
      // Leave the last known count in place — see [_labelCounts].
      debugPrint('[Gmail] label count fetch failed for $id: $e');
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
      if (skip == 0) {
        // Fresh load: discard any stored page token for this folder.
        _pageTokens.remove(folderId);
      }

      final queryParams = <String, dynamic>{
        'maxResults': top,
        'labelIds': ?folderId,
        'pageToken': ?_pageTokens[folderId],
      };

      // Plain like the per-thread fetches below, and decoded here rather than in
      // an isolate: this response is only thread ids and a page token, so the
      // decode is trivial — the bulk is in the bodies, which do go to the
      // isolate. Keeping one response type across the message endpoints also
      // keeps them stubbable as one thing in tests, since a Dart `Invocation`
      // does not carry the type argument that would tell `get<Map>` from
      // `get<String>`.
      final listResp = await _dio.get<String>(
        '/users/me/threads',
        queryParameters: queryParams,
        options: Options(responseType: ResponseType.plain),
      );

      final rawList = listResp.data;
      if (rawList == null || rawList.isEmpty) return [];
      final data = jsonDecode(rawList) as Map<String, dynamic>;

      // Store the next page token so the next load-more call can advance.
      final nextToken = data['nextPageToken'] as String?;
      if (nextToken != null) {
        _pageTokens[folderId] = nextToken;
      } else {
        _pageTokens.remove(folderId);
      }

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

      // Fetch every thread's messages concurrently (network only — no
      // decoding), then parse the whole page in a single background isolate. One
      // compute() for the page rather than one per thread: each call spawns its
      // own isolate, and paying that 25 times over would cost more than the
      // parse.
      //
      // A chunk at a time, for the same reason the label counts are chunked
      // (see [_labelCountConcurrency]) — and it is worse here, because a 429
      // costs `RetryInterceptor` a second or more of backoff, so firing a whole
      // page at once made the page slower rather than faster.
      final threadIds = [
        for (final t in threads) (t as Map<String, dynamic>)['id'] as String,
      ];
      final rawBodies = <String?>[];
      for (var i = 0; i < threadIds.length; i += _threadFetchConcurrency) {
        final chunk = threadIds.sublist(
          i,
          (i + _threadFetchConcurrency).clamp(0, threadIds.length),
        );
        rawBodies.addAll(await Future.wait(chunk.map(_fetchThreadRaw)));
      }

      return compute(
        parseGmailThreads,
        GmailThreadParseParams(
          rawThreadBodies: rawBodies,
          excludeLabels: excludeLabels,
        ),
      );
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  /// Gmail's conversationId *is* the thread id, so this is a direct thread
  /// fetch. Unlike the folder listing above nothing is excluded — a thread
  /// opened on its own should show all of its messages, including any that
  /// have since been trashed or marked spam. [folderId] is ignored.
  @override
  Future<List<EmailModel>> getConversationMessages(
    String conversationId, {
    String? folderId,
  }) async {
    final raw = await _fetchThreadRaw(conversationId);
    if (raw == null) return [];
    return compute(
      parseGmailThreads,
      GmailThreadParseParams(
        rawThreadBodies: [raw],
        excludeLabels: const {},
      ),
    );
  }

  /// Fetches one message's list-projection response **undecoded**, for a parser
  /// isolate to decode. Returns null when the fetch fails, which the batch
  /// parser skips. Shared by the search path and the history sync.
  Future<String?> _fetchMessageMetadataRaw(String id) async {
    try {
      final resp = await _dio.get<String>(
        '/users/me/messages/$id',
        queryParameters: {
          'format': 'metadata',
          'metadataHeaders': ['From', 'To', 'Cc', 'Subject', 'Date'],
        },
        options: Options(responseType: ResponseType.plain),
      );
      return resp.data;
    } catch (_) {
      return null;
    }
  }

  /// Fetches one thread's response **undecoded**, for a parser isolate to
  /// decode. Returns null when the fetch fails, which the batch parser skips.
  Future<String?> _fetchThreadRaw(String threadId) async {
    try {
      final resp = await _dio.get<String>(
        '/users/me/threads/$threadId',
        queryParameters: {
          'format': 'metadata',
          'metadataHeaders': ['From', 'To', 'Cc', 'Subject', 'Date'],
        },
        options: Options(responseType: ResponseType.plain),
      );
      return resp.data;
    } catch (_) {
      return null;
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
      // Plain, decoded here — an id list, same as the thread index in getEmails.
      final listResp = await _dio.get<String>(
        '/users/me/messages',
        queryParameters: {'maxResults': top, 'q': query},
        options: Options(responseType: ResponseType.plain),
      );

      final rawList = listResp.data;
      if (rawList == null || rawList.isEmpty) return [];
      final data = jsonDecode(rawList) as Map<String, dynamic>;

      final messages = data['messages'] as List<dynamic>? ?? [];
      if (messages.isEmpty) return [];

      final futures = messages.map((m) =>
          _fetchMessageMetadataRaw((m as Map<String, dynamic>)['id'] as String));

      // As in getEmails: fetch concurrently, decode once off the UI isolate.
      final rawBodies = await Future.wait(futures);
      return compute(parseGmailMetadataMessages, rawBodies);
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<EmailModel> getEmail(String id) async {
    try {
      // Undecoded: the parser isolate does the jsonDecode as well as the parse.
      // A `format=full` body carries the message body and every inline image as
      // base64, so decoding it here would leave the larger half of the cost on
      // the UI isolate — which is the whole reason this moved.
      final resp = await _dio.get<String>(
        '/users/me/messages/$id',
        queryParameters: {'format': 'full'},
        options: Options(responseType: ResponseType.plain),
      );
      final raw = resp.data;
      if (raw == null || raw.isEmpty) {
        throw ServerException(message: 'Empty response for message $id');
      }

      final parsed = await compute(parseGmailFullMessage, raw);
      final email = parsed.email;

      // If no ICS was inlined in the payload, check for a calendar attachment
      // stored separately — Gmail omits body.data for some parts even when
      // the content is small, requiring a dedicated attachment fetch. The
      // isolate reported the id while it had the payload open.
      MeetingInvite? meetingInvite = email.meetingInvite;
      final icsId = parsed.icsAttachmentId;
      if (meetingInvite == null && icsId != null) {
        try {
          final ar = await _dio.get<String>(
            '/users/me/messages/$id/attachments/$icsId',
            options: Options(responseType: ResponseType.plain),
          );
          final body = ar.data;
          if (body != null && body.isNotEmpty) {
            meetingInvite = await compute(parseGmailIcsAttachment, body);
          }
        } catch (_) {}
      }

      // Large inline attachments (>2 MB) have only an attachmentId — no data
      // field in the payload. Fetch them concurrently and merge.
      final pending = parsed.pendingInline;

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
        isFlagged: email.isFlagged,
        receivedDateTime: email.receivedDateTime,
        importance: email.importance,
        parentFolderId: email.parentFolderId,
        folderIds: email.folderIds,
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
      String messageId, GmailPendingInline a) async {
    try {
      final response = await _dio.get<String>(
        '/users/me/messages/$messageId/attachments/${a.attachmentId}',
        options: Options(responseType: ResponseType.plain),
      );
      final body = response.data;
      if (body == null || body.isEmpty) return null;
      // These are the >2 MB images, so the base64 decode is worth an isolate.
      final bytes = await compute(decodeGmailAttachmentBytes, body);
      if (bytes == null) return null;
      return InlineAttachment(
        contentId: a.contentId,
        contentType: a.contentType,
        contentBytes: bytes,
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
  //
  // Message parsing lives in gmail_message_parser.dart as top-level functions
  // so it can run in a background isolate via compute(). Only label naming,
  // which is cheap and never touches a message body, is left here.

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
        ..from = [MailAddress(displayName.isEmpty ? null : displayName, fromEmail)]
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
      // Plain for the same reason as the rest of the message endpoints, though
      // here the decode stays local: MessageBuilder.prepareReplyToMessage needs
      // the original as a live MimeMessage on this isolate, so there is nothing
      // to gain by decoding elsewhere and no way to send the object back. This
      // is a user-initiated one-off rather than the polling path.
      final rawResp = await _dio.get<String>(
        '/users/me/messages/$messageId',
        queryParameters: {'format': 'raw'},
        options: Options(responseType: ResponseType.plain),
      );
      final rawBody = rawResp.data;
      if (rawBody == null || rawBody.isEmpty) {
        throw const ServerException(message: 'Message not found');
      }
      final rawJson = jsonDecode(rawBody) as Map<String, dynamic>;
      final rawBase64 = rawJson['raw'] as String?;
      if (rawBase64 == null) {
        throw const ServerException(message: 'No raw data in response');
      }
      final threadId = rawJson['threadId'] as String?;

      final rawBytes = base64Url.decode(padGmailBase64(rawBase64));
      final original = MimeMessage.parseFromData(rawBytes);

      final fromEmail = await _getUserEmail();
      final builder = MessageBuilder.prepareReplyToMessage(
        original,
        MailAddress(displayName.isEmpty ? null : displayName, fromEmail),
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
      final resp = await _dio.get<String>(
        '/users/me/messages/$messageId',
        queryParameters: {'format': 'full'},
        options: Options(responseType: ResponseType.plain),
      );
      final raw = resp.data;
      if (raw == null || raw.isEmpty) {
        throw const ServerException(message: 'Message not found');
      }

      final source = await compute(parseGmailForwardSource, raw);
      final threadId = source.threadId;
      final originalSubject = source.subject;

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
        builder.from = [MailAddress(displayName.isEmpty ? null : displayName, fromEmail)];
      }

      // Compose body already contains the full forwarded content the user can edit;
      // send it as-is rather than re-appending the original.
      if (bodyType == EmailBodyType.html) {
        builder.addTextHtml(comment);
      } else {
        builder.addTextPlain(comment);
      }

      for (final att in source.attachments) {
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
      _cachedUserEmail =
          (await _profile())['emailAddress'] as String? ?? '';
      return _cachedUserEmail!;
    } catch (_) {
      return '';
    }
  }

  /// `users.getProfile`, decoded here rather than in an isolate: it is four
  /// fields, the same reason the thread and search indexes are decoded locally.
  ///
  /// Plain like every other request this class makes, and that is not a detail —
  /// Mockito cannot tell `get<Map>` from `get<String>` (a Dart `Invocation` does
  /// not carry the type argument), so a second response type on any endpoint the
  /// message path also touches makes the stubs collide and the last one
  /// registered win.
  Future<Map<String, dynamic>> _profile() async {
    final resp = await _dio.get<String>(
      '/users/me/profile',
      options: Options(responseType: ResponseType.plain),
    );
    final raw = resp.data;
    if (raw == null || raw.isEmpty) return const {};
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  @override
  Future<String?> moveEmail(String id, String destinationFolderId) async {
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
    // Gmail's "move" is a label change — the message id is stable.
    return id;
  }

  @override
  Future<String?> reportJunk(String id) async {
    await _dio.post<void>(
      '/users/me/messages/$id/modify',
      data: {
        'addLabelIds': ['SPAM'],
        'removeLabelIds': ['INBOX'],
      },
    );
    return id;
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
      final response = await _dio.get<String>(
        '/users/me/messages/$messageId/attachments/$attachmentId',
        options: Options(responseType: ResponseType.plain),
      );
      final body = response.data;
      if (body == null || body.isEmpty) {
        throw const ServerException(message: 'Empty response from server');
      }
      // An attachment is by definition the large kind of payload, so both the
      // jsonDecode and the base64 decode go to a background isolate.
      final bytes = await compute(decodeGmailAttachmentBytes, body);
      if (bytes == null) {
        throw const ServerException(message: 'No attachment data in response');
      }
      return bytes;
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<Uint8List> getRawEmailBytes(String id) async {
    try {
      // Plain, like every other message fetch in this file — jsonDecode of a
      // full message (body + every inline image as base64) is the expensive
      // half, and letting Dio decode it would put that back on the UI
      // isolate. There's no parsing to do here beyond the outer envelope
      // though, so it stays inline rather than going through compute().
      final rawResp = await _dio.get<String>(
        '/users/me/messages/$id',
        queryParameters: {'format': 'raw'},
        options: Options(responseType: ResponseType.plain),
      );
      final rawBody = rawResp.data;
      if (rawBody == null || rawBody.isEmpty) {
        throw const ServerException(message: 'Message not found');
      }
      final rawJson = jsonDecode(rawBody) as Map<String, dynamic>;
      final rawBase64 = rawJson['raw'] as String?;
      if (rawBase64 == null) {
        throw const ServerException(message: 'No raw data in response');
      }
      return base64Url.decode(padGmailBase64(rawBase64));
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<Map<SpecialFolderKind, String>> getSpecialFolderIds() async {
    // Gmail's special labels are well-known constant ids, not per-account —
    // no request needed. Gmail has no distinct Archive: "archiving" there
    // just means removing the INBOX label, so that kind is omitted rather
    // than guessed at.
    return const {
      SpecialFolderKind.inbox: 'INBOX',
      SpecialFolderKind.sent: 'SENT',
      SpecialFolderKind.trash: 'TRASH',
      SpecialFolderKind.junk: 'SPAM',
    };
  }

  @override
  Future<String> insertRawMessage({
    required String folderId,
    required Uint8List rawBytes,
    required DateTime receivedAt,
    required bool isRead,
  }) async {
    try {
      // `insert` (not `import`) deliberately: import re-runs Gmail's spam
      // classifier and delivery scanning, which could reroute a message away
      // from the label we're explicitly placing it under. insert bypasses
      // that, matching IMAP APPEND's "land exactly where told" semantics.
      final encoded = base64Url.encode(rawBytes).replaceAll('=', '');
      final resp = await _dio.post<Map<String, dynamic>>(
        '/users/me/messages',
        queryParameters: {'internalDateSource': 'dateHeader'},
        data: {
          'raw': encoded,
          'labelIds': [folderId, if (!isRead) 'UNREAD'],
        },
      );
      final id = resp.data?['id'] as String?;
      if (id == null) {
        throw const ServerException(message: 'No message ID in response');
      }
      return id;
    } on DioException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<String> createFolder({
    required String parentFolderId,
    required String displayName,
  }) async {
    try {
      // Empty parentFolderId is the root sentinel (account migration's
      // folder-hierarchy build-out is the only caller that ever creates a
      // genuine top-level folder — every other caller creates a child of a
      // folder the user is looking at). Skip the parent-name lookup below;
      // there is no parent label to prefix with.
      String labelName = displayName;
      if (parentFolderId.isNotEmpty) {
        final parentResp = await _dio.get<Map<String, dynamic>>(
          '/users/me/labels/$parentFolderId',
        );
        final parentName = parentResp.data?['name'] as String? ?? '';
        labelName =
            parentName.isEmpty ? displayName : '$parentName/$displayName';
      }
      try {
        final resp = await _dio.post<Map<String, dynamic>>(
          '/users/me/labels',
          data: {'name': labelName},
        );
        final id = resp.data?['id'] as String?;
        if (id == null) {
          throw const ServerException(message: 'No label ID in response');
        }
        return id;
      } on DioException catch (e) {
        // A duplicate label name is success from this method's point of
        // view — callers (notably account migration, on every resume) treat
        // "the folder already exists" the same as having just created it.
        if (e.response?.statusCode != 409) rethrow;
        final listResp =
            await _dio.get<Map<String, dynamic>>('/users/me/labels');
        final labels = (listResp.data?['labels'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        for (final label in labels) {
          if ((label['name'] as String?) == labelName) {
            return label['id'] as String;
          }
        }
        rethrow;
      }
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
  Future<String> moveFolder({
    required String folderId,
    required String newParentFolderId,
  }) async {
    try {
      // List all labels once — we resolve names, find descendants, and rename.
      final listResp =
          await _dio.get<Map<String, dynamic>>('/users/me/labels');
      final labels = (listResp.data?['labels'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      final nameById = <String, String>{};
      for (final l in labels) {
        final id = l['id'] as String?;
        final name = l['name'] as String?;
        if (id != null && name != null) nameById[id] = name;
      }

      // Virtual folders have no real label — their id encodes their full path.
      String? nameFor(String id) => id.startsWith('__virtual__')
          ? id.substring('__virtual__'.length)
          : nameById[id];

      final oldName = nameFor(folderId);
      final destName = nameFor(newParentFolderId);
      if (oldName == null || destName == null) {
        throw ServerException(message: 'Folder not found.');
      }
      final leaf = oldName.contains('/')
          ? oldName.substring(oldName.lastIndexOf('/') + 1)
          : oldName;
      final newName = '$destName/$leaf';

      // Rename the moved label (if it is a real one) and every descendant
      // label, replacing the old path prefix with the new one.
      for (final l in labels) {
        final id = l['id'] as String?;
        final name = l['name'] as String?;
        if (id == null || name == null) continue;
        if (name == oldName) {
          await _dio.patch<void>(
            '/users/me/labels/$id',
            data: {'name': newName},
          );
        } else if (name.startsWith('$oldName/')) {
          final renamed = '$newName${name.substring(oldName.length)}';
          await _dio.patch<void>(
            '/users/me/labels/$id',
            data: {'name': renamed},
          );
        }
      }

      // A real label keeps its id through a rename; a virtual folder's id
      // *is* its path, so moving it mints a different one.
      return folderId.startsWith('__virtual__')
          ? '__virtual__$newName'
          : folderId;
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
        fromDisplayName: displayName,
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
        fromDisplayName: displayName,
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

  // ---------------------------------------------------------------------------
  // Incremental sync — users.history.list
  // ---------------------------------------------------------------------------

  /// History records per page, and how many pages one call will follow.
  ///
  /// 500 is Gmail's own maximum. The budget bounds a mailbox that has changed
  /// enormously since the last poll — a bulk archive, a filter run over an
  /// import — into a fixed number of sequential round trips, the same way the
  /// Graph delta path bounds an initial sync. Nothing is lost when it runs out:
  /// the cursor is left at the last record read, so the next poll carries on
  /// from there.
  static const _historyPageSize = 500;
  static const _historyPageBudget = 10;

  /// Messages one call will re-fetch before giving up on being incremental.
  ///
  /// A change set larger than this is not worth several hundred round trips, and
  /// truncating it is not an option — a change dropped while the cursor advances
  /// past it is invisible for ever, which is the whole class of bug this path
  /// exists to remove. Reported as a `ServerException` with no status instead,
  /// which the poller treats as fatal: it drops the cursor and re-bootstraps
  /// from the mailbox's current `historyId`.
  static const _historyUpsertBudget = 250;

  /// Messages fetched concurrently while resolving a change set. A steady-state
  /// poll has a handful; this only bites after a burst.
  static const _historyFetchConcurrency = 25;

  /// The label a cursor is scoped to.
  ///
  /// The poller addresses the Inbox by Graph's well-known folder name, so
  /// `inbox` in any case means Gmail's `INBOX` label. Resolving it here is what
  /// lets the cursor live under the same `(accountId, 'inbox')` key for both
  /// providers, with nothing in the poller having to know which one it is
  /// talking to. Anything else is already a label id.
  static String _deltaLabelId(String folderId) =>
      folderId.toUpperCase() == 'INBOX' ? 'INBOX' : folderId;

  @override
  Future<MailDeltaResult> syncMailDelta(
    String folderId, {
    String? deltaLink,
  }) async {
    final label = _deltaLabelId(folderId);

    try {
      if (deltaLink == null) {
        // Bootstrap: seed the cursor and fetch nothing. Unlike Graph's initial
        // delta call there is no page to walk — a history stream can only start
        // from a historyId, and the endpoint has no "as of now" form — so this
        // costs one request and reports no messages. The poller bumps
        // pollGeneration after a bootstrap, and that refresh is what pulls the
        // folder itself.
        return MailDeltaResult(
          upserted: const [],
          removedIds: const [],
          deltaLink: await _currentHistoryId(),
        );
      }

      // Pages are collected undecoded and folded together at the end, off the
      // UI isolate. Paging has to stay here: each page's token is only known
      // once that page has arrived.
      final rawPages = <String>[];
      String? pageToken;
      var truncated = false;

      for (var page = 0;; page++) {
        final resp = await _dio.get<String>(
          '/users/me/history',
          queryParameters: {
            'startHistoryId': deltaLink,
            // Everything that can change a folder's contents or a row's state.
            // labelAdded/labelRemoved are the important pair: a cross-folder
            // move, an archive, a read and a star are all label changes, and
            // none of them shifts the unread/total counts the poller used to
            // compare — two offsetting ones cancelled out and were invisible
            // for good.
            'historyTypes': const [
              'messageAdded',
              'messageDeleted',
              'labelAdded',
              'labelRemoved',
            ],
            'maxResults': _historyPageSize,
            'pageToken': ?pageToken,
          },
          options: Options(responseType: ResponseType.plain),
        );

        final raw = resp.data ?? '';
        if (raw.isNotEmpty) rawPages.add(raw);

        // Scanned out of the raw body rather than decoded, exactly as the
        // contacts fetchers do it: this one field is all the fetching isolate
        // needs, and decoding the page here would put back the cost of handing
        // it to compute() below.
        pageToken = raw.isEmpty ? null : googleNextPageToken(raw);
        if (pageToken == null) break;
        if (page + 1 >= _historyPageBudget) {
          truncated = true;
          break;
        }
      }

      // No labelId filter on the request, deliberately: a message that has just
      // *lost* the folder's label no longer matches it, so filtering
      // server-side would hide the moves and archives this path was added to
      // notice. The feed is mailbox-wide and the isolate reduces it to one
      // label's answer.
      final changes = await compute(
        parseGmailHistoryPages,
        GmailHistoryParseParams(rawPages: rawPages, folderLabelId: label),
      );

      // Where the next poll starts. The mailbox's current historyId is only the
      // right answer when every page was read — it means "now", not "the end of
      // what was applied", so storing it after a truncated walk would skip the
      // remainder for ever. A truncated walk resumes from the last record
      // instead, and a run that reported neither leaves the cursor where it
      // was: replaying a history range is idempotent, losing one is not.
      final cursor =
          (truncated ? changes.lastRecordId : changes.currentHistoryId) ??
              deltaLink;

      if (changes.upsertedIds.length > _historyUpsertBudget) {
        throw ServerException(
          message: '${changes.upsertedIds.length} messages changed since the '
              'last sync — re-bootstrapping instead of fetching them all',
        );
      }

      return MailDeltaResult(
        upserted: await _fetchHistoryMessages(changes.upsertedIds),
        removedIds: changes.removedIds,
        movedOutIds: changes.movedOutIds,
        deltaLink: cursor,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        // Gmail's answer for a startHistoryId older than the week or so of
        // history it keeps. Rethrown with the status intact because that is
        // what the poller recognises as "drop the cursor and re-bootstrap".
        throw const ServerException(
          message: 'startHistoryId is no longer valid — history has expired',
          statusCode: 404,
        );
      }
      throw _mapException(e);
    }
  }

  /// The mailbox's current `historyId`, the only way to start a history stream.
  Future<String> _currentHistoryId() async {
    final historyId = (await _profile())['historyId']?.toString();
    if (historyId == null || historyId.isEmpty) {
      // Without a cursor there is no incremental sync at all. No status code,
      // so the poller treats it as fatal and tries a fresh bootstrap rather
      // than counting it towards a streak against a token it never got.
      throw const ServerException(message: 'Gmail profile carried no historyId');
    }
    return historyId;
  }

  /// Re-fetches the messages a history walk named, and parses them all in one
  /// isolate call.
  ///
  /// A history record carries only ids and labels, so a row the folder can show
  /// has to be fetched. A fetch that fails yields null and is skipped rather
  /// than failing the sync: the usual cause is a message deleted between the
  /// history page and now, and that deletion carries a higher historyId than
  /// the cursor being stored, so the next poll reports it properly.
  Future<List<EmailModel>> _fetchHistoryMessages(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final rawBodies = <String?>[];
    for (var i = 0; i < ids.length; i += _historyFetchConcurrency) {
      final chunk = ids.sublist(
          i, (i + _historyFetchConcurrency).clamp(0, ids.length));
      rawBodies.addAll(await Future.wait(chunk.map(_fetchMessageMetadataRaw)));
    }
    // One compute() for the whole change set rather than one per message: each
    // call spawns an isolate, so per-message would cost more than the parse.
    return compute(parseGmailMetadataMessages, rawBodies);
  }

  Exception _mapException(DioException e) {
    // AuthInterceptor.onRequest can throw AuthException directly (e.g. no
    // stored token, or a failed proactive refresh) before any HTTP request
    // is sent. Dio wraps that throw in a DioException with no response, so
    // it must be unwrapped here or it falls through to a generic
    // ServerException and the UI never learns re-authentication is needed.
    if (e.error is AuthException) return e.error as AuthException;
    // The same unwrap for a proactive refresh that never reached the token
    // endpoint: offline is neither a credential problem nor a server error, and
    // falling through would replace it with Dio's own boilerplate message.
    if (e.error is NetworkException) return e.error as NetworkException;

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

/// Inputs for [_buildDraftRawBase64]. Kept as plain, isolate-transferable
/// data (no [MessageBuilder]/[MimeMessage] instances) since [compute] runs
/// the builder on a background isolate.
class _DraftMimeParams {
  const _DraftMimeParams({
    required this.fromAddress,
    this.fromDisplayName = '',
    required this.toAddresses,
    required this.ccAddresses,
    required this.subject,
    required this.body,
    required this.isHtml,
    required this.attachments,
  });

  final String fromAddress;
  final String fromDisplayName;
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
    ..from = [MailAddress(p.fromDisplayName.isEmpty ? null : p.fromDisplayName, p.fromAddress)]
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
