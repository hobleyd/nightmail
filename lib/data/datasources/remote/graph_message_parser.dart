import 'dart:convert';
import 'dart:typed_data';

import '../../../domain/entities/inline_attachment.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../models/email_model.dart';
import '../../models/mail_delta_result.dart';
// `isGraphUrl` lives beside `graphNextLink`, which is the other half of the same
// job — reading a continuation link out of a raw Graph page.
import 'contact_bulk_parser.dart' show isGraphUrl;
import 'ics_meeting_invite.dart';

/// Microsoft Graph message parsing, off the UI isolate.
///
/// Same arrangement as `gmail_message_parser.dart`: the datasource requests
/// `ResponseType.plain` and hands the **undecoded** body straight to `compute()`,
/// because `jsonDecode` is itself a large share of the cost. A Graph message
/// carries its body as an HTML string and its inline images as base64 inside the
/// same JSON document, so a single `/me/messages/{id}` response can be several
/// megabytes — decoded, then base64-decoded again per inline image.
///
/// [EmailModel.fromJson] is already a pure static factory, so unlike Gmail there
/// is no parsing logic to relocate here; what this file adds is the isolate
/// boundary and the batching that makes it worth crossing.

/// Parses a `value`-wrapped collection response (list, search, conversation).
/// `compute()` entry point.
List<EmailModel> parseGraphMessageCollection(String rawJson) {
  final data = jsonDecode(rawJson) as Map<String, dynamic>;
  final value = data['value'] as List<dynamic>? ?? [];
  final out = <EmailModel>[];
  for (final e in value) {
    try {
      out.add(EmailModel.fromJson(e as Map<String, dynamic>));
    } catch (_) {
      // One unparseable item must not lose the rest of the page — Graph delta
      // feeds in particular carry occasional half-populated system messages.
    }
  }
  return out;
}

/// Parses several collection responses at once, de-duplicated by message id.
///
/// One `compute()` for the whole set rather than one per response: each call
/// spawns an isolate, and the list path fetches a conversation per unique thread
/// on the page — paying isolate setup that many times would cost more than the
/// parse itself. Earlier entries win, matching the previous `putIfAbsent` merge.
List<EmailModel> parseGraphMessageCollections(List<String?> rawBodies) {
  final byId = <String, EmailModel>{};
  for (final raw in rawBodies) {
    if (raw == null) continue;
    try {
      for (final email in parseGraphMessageCollection(raw)) {
        byId.putIfAbsent(email.id, () => email);
      }
    } catch (_) {
      // Skip the response that failed, keep the others.
    }
  }
  return byId.values.toList();
}

/// Parses a single-message response. `compute()` entry point.
EmailModel parseGraphMessage(String rawJson) {
  return EmailModel.fromJson(jsonDecode(rawJson) as Map<String, dynamic>);
}

/// A single-message parse, plus the inline attachments that still need their
/// own fetch.
///
/// `contentId` and `contentBytes` live on the `fileAttachment` subtype and
/// cannot be requested through `$expand` (which targets the base `attachment`
/// type), so an inline image's bytes are never in the message response and each
/// one needs a follow-up GET. Reporting the ids from here is what lets the
/// caller discover them without decoding the document on the UI isolate.
class GraphFullMessage {
  const GraphFullMessage({
    required this.email,
    required this.pendingInlineAttachmentIds,
    required this.icsAttachmentId,
  });

  final EmailModel email;

  /// Attachment ids declared `isInline` whose bytes were not included.
  final List<String> pendingInlineAttachmentIds;

  /// Attachment id of a calendar part, or null when the message has none or
  /// Graph already classified the message itself (`meetingMessageType`).
  ///
  /// `$expand` returns an attachment's name and contentType but never its
  /// bytes, so the ICS behind this id still needs its own GET — the same shape
  /// as Gmail's `GmailFullMessage.icsAttachmentId`, for the same reason.
  final String? icsAttachmentId;
}

/// Parses a single-message response and reports its inline attachment ids.
/// `compute()` entry point.
GraphFullMessage parseGraphFullMessage(String rawJson) {
  final json = jsonDecode(rawJson) as Map<String, dynamic>;
  final email = EmailModel.fromJson(json);

  final pending = <String>[];
  String? icsAttachmentId;
  for (final a
      in (json['attachments'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>()) {
    if (a['isInline'] != true) {
      if (email.meetingInvite == null && icsAttachmentId == null) {
        final id = a['id'] as String?;
        if (id != null && id.isNotEmpty && _isCalendarAttachment(a)) {
          icsAttachmentId = id;
        }
      }
      continue;
    }
    final id = a['id'] as String?;
    if (id == null || id.isEmpty) continue;
    // Guarded rather than assumed: if Graph ever does include the bytes, the
    // parse above already used them and there is nothing left to fetch.
    final bytes = a['contentBytes'] as String?;
    if (bytes != null && bytes.isNotEmpty) continue;
    pending.add(id);
  }

  return GraphFullMessage(
    email: email,
    pendingInlineAttachmentIds: pending,
    icsAttachmentId: icsAttachmentId,
  );
}

/// Whether an expanded attachment is a calendar part. Matched on filename as
/// well as content type: senders routinely attach an `.ics` as
/// `application/octet-stream`.
bool _isCalendarAttachment(Map<String, dynamic> attachment) {
  final contentType =
      (attachment['contentType'] as String? ?? '').toLowerCase();
  if (contentType.startsWith('text/calendar') ||
      contentType.startsWith('application/ics')) {
    return true;
  }
  return (attachment['name'] as String? ?? '').toLowerCase().endsWith('.ics');
}

/// Decodes a separately-fetched `/attachments/{id}` response holding an ICS
/// part and turns it into a [MeetingInvite]. `compute()` entry point.
MeetingInvite? parseGraphIcsAttachment(String rawJson) {
  try {
    final json = jsonDecode(rawJson) as Map<String, dynamic>;
    final contentBytes = json['contentBytes'] as String?;
    if (contentBytes == null || contentBytes.isEmpty) return null;
    return buildMeetingInviteFromIcs(utf8.decode(base64Decode(contentBytes)));
  } catch (_) {
    return null;
  }
}

/// Decodes separately-fetched inline attachment responses into attachments.
/// `compute()` entry point.
///
/// Returned rather than merged into the message so the document does not have to
/// be decoded a second time: the caller already holds the parsed message, and
/// rebuilding it with this list is pure object construction.
List<InlineAttachment> parseGraphInlineAttachments(List<String> rawBodies) {
  final out = <InlineAttachment>[];
  for (final raw in rawBodies) {
    try {
      final a = jsonDecode(raw) as Map<String, dynamic>;
      final contentId = a['contentId'] as String?;
      final contentBytes = a['contentBytes'] as String?;
      if (contentId == null || contentId.isEmpty) continue;
      if (contentBytes == null || contentBytes.isEmpty) continue;
      out.add(InlineAttachment(
        contentId: contentId,
        contentType: a['contentType'] as String? ?? 'application/octet-stream',
        contentBytes: base64Decode(contentBytes),
      ));
    } catch (_) {
      // A malformed or oversized part simply renders as a missing image.
    }
  }
  return out;
}

/// The upserts and deletions carried by a delta sync.
class GraphDeltaParseResult {
  const GraphDeltaParseResult({
    required this.upserted,
    required this.removedIds,
    this.movedOutIds = const [],
    this.fieldUpdates = const [],
  });

  final List<EmailModel> upserted;

  /// Messages Graph reported as `@removed` with `reason: 'deleted'` — genuinely
  /// gone from the mailbox.
  final List<String> removedIds;

  /// Messages Graph reported as `@removed` with `reason: 'changed'` — no longer
  /// in the folder being synced, but still in the mailbox somewhere. Almost
  /// always a move.
  ///
  /// Kept apart from [removedIds] because the two want different treatment: a
  /// delete should take the message's cached inline images with it, whereas a
  /// move only means the row belongs to a different folder now, and evicting
  /// those images makes the destination folder re-download every one.
  final List<String> movedOutIds;

  /// Items that carried only the properties that changed — see
  /// [MailDeltaFieldUpdate].
  final List<MailDeltaFieldUpdate> fieldUpdates;
}

/// Reads a delta item that is not a whole message as the field change it is.
///
/// A delta item with no `receivedDateTime` is the tell: the projection always
/// asks for one and every real message has one, so its absence means Graph sent
/// the changed properties rather than the message. Returns null when there is
/// nothing here this app stores.
MailDeltaFieldUpdate? _fieldUpdateFrom(Map<String, dynamic> item) {
  final id = item['id'] as String?;
  if (id == null) return null;
  final rawFlag = item['flag'];
  final update = MailDeltaFieldUpdate(
    id: id,
    isRead: item['isRead'] as bool?,
    isFlagged: rawFlag is Map<String, dynamic>
        ? (rawFlag['flagStatus'] as String?)?.toLowerCase() == 'flagged'
        : null,
  );
  return update.isEmpty ? null : update;
}

/// Parses every page of a delta sync in one pass. `compute()` entry point.
///
/// Delta paging is sequential — each page's `@odata.nextLink` is only known once
/// that page has arrived — so the pages cannot be fetched in parallel and the
/// links have to be read on the calling isolate (see [graphDeltaLink] and
/// `graphNextLink`). Accumulating the raw pages and parsing them together is
/// what keeps that from meaning "decode each page on the UI isolate": the pages
/// use the list projection, not full bodies, so holding them is cheap.
GraphDeltaParseResult parseGraphDeltaPages(List<String> rawPages) {
  final upserted = <EmailModel>[];
  final removedIds = <String>[];
  final movedOutIds = <String>[];
  final fieldUpdates = <MailDeltaFieldUpdate>[];

  for (final raw in rawPages) {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      for (final item
          in (data['value'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>()) {
        if (item.containsKey('@removed')) {
          final id = item['id'] as String?;
          if (id == null) continue;
          // Graph distinguishes 'deleted' (gone from the mailbox) from
          // 'changed' (still in the mailbox, no longer in this folder — a move).
          // An unrecognised or absent reason is treated as a delete, which is
          // the conservative reading: the row leaves this folder either way, and
          // the only cost of being wrong is re-downloading inline images.
          final reason = (item['@removed'] as Map<String, dynamic>?)?['reason'];
          if (reason == 'changed') {
            movedOutIds.add(id);
          } else {
            removedIds.add(id);
          }
        } else if (!item.containsKey('receivedDateTime')) {
          // Not a whole message — the changed properties on their own. Caching
          // it as a message blanks the row it belongs to; apply it to that row
          // instead.
          final update = _fieldUpdateFrom(item);
          if (update != null) fieldUpdates.add(update);
        } else {
          try {
            upserted.add(EmailModel.fromJson(item));
          } catch (_) {
            // Graph delta feeds carry the occasional half-populated system
            // message; losing one must not discard the page.
          }
        }
      }
    } catch (_) {
      // A page that will not decode loses that page, not the whole sync.
    }
  }

  return GraphDeltaParseResult(
    upserted: upserted,
    removedIds: removedIds,
    movedOutIds: movedOutIds,
    fieldUpdates: fieldUpdates,
  );
}

final _graphDeltaLinkPattern =
    RegExp(r'"@odata\.deltaLink"\s*:\s*"((?:[^"\\]|\\.)+)"');

/// The absolute `@odata.deltaLink` in a raw Graph delta page, or null while more
/// pages remain. Unescaped the same way `graphNextLink` is — Graph escapes the
/// separators inside the URL (`\/` for a slash, `&` for an ampersand), and
/// following the link verbatim otherwise 400s the next sync.
///
/// Scanning the raw page cannot pick up a link out of a message's own content,
/// even though the pattern is unanchored and `bodyPreview` is in the projection:
/// the pattern needs an *unescaped* `"` on both sides of the key, and a `"`
/// inside a JSON string value is always `\"`. It is still passed through
/// [isGraphUrl] before being returned, so a link this app would go on to GET
/// with the account's bearer token attached has to be Graph's own host.
String? graphDeltaLink(String body) {
  // Written as two adjacent literals so the sequence is not itself read as a
  // Dart escape.
  const ampersandEscape = '\\' 'u0026';
  final raw = _graphDeltaLinkPattern.firstMatch(body)?.group(1);
  if (raw == null) return null;
  final url = raw.replaceAll(r'\/', '/').replaceAll(ampersandEscape, '&');
  return isGraphUrl(url) ? url : null;
}

/// Decodes a Graph attachment response's `contentBytes` to bytes. `compute()`
/// entry point — an attachment is by definition large enough to be worth it.
Uint8List? decodeGraphAttachmentBytes(String rawJson) {
  try {
    final data = jsonDecode(rawJson) as Map<String, dynamic>;
    final contentBytes = data['contentBytes'] as String?;
    if (contentBytes == null || contentBytes.isEmpty) return null;
    return base64Decode(contentBytes);
  } catch (_) {
    return null;
  }
}
