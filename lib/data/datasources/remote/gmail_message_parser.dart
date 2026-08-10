import 'dart:convert';
import 'dart:typed_data';

import '../../../core/utils/html_entities.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/email_attachment.dart';
import '../../../domain/entities/inline_attachment.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../models/email_address_model.dart';
import '../../models/email_model.dart';
import 'ics_meeting_invite.dart';

/// Gmail message parsing, off the UI isolate.
///
/// Every entry point here takes **undecoded response bodies** and is safe to
/// hand to `compute()`. That is the whole point: `jsonDecode` of a `format=full`
/// message is itself a large part of the cost (the body and every inline image
/// arrive as base64 inside the JSON), so letting Dio decode the response would
/// leave half the work on the UI isolate no matter what this file did. The
/// datasource therefore requests `ResponseType.plain` and passes the raw string
/// straight through — the same arrangement `contact_bulk_parser.dart` uses.
///
/// The expensive parts, in rough order: `jsonDecode` of the envelope, the
/// base64 decode of each body part, and the base64 decode of inline image
/// bytes. All of it is pure data transformation with no I/O, which is why it
/// moves cleanly.
///
/// Note the return values cross an isolate boundary, so everything reachable
/// from them must be plain sendable data — [EmailModel] and friends are, being
/// strings, enums, `DateTime`s and `Uint8List`s.

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

/// A `format=full` single-message parse.
///
/// Carries more than the message because two things can only be discovered by
/// walking the payload, and neither can be finished without another network
/// round-trip the isolate cannot make:
///
/// * an ICS part Gmail stored as a separate attachment rather than inlining, and
/// * inline images over ~2 MB, which arrive with an `attachmentId` and no data.
///
/// Reporting them back means the payload is walked once, here, instead of being
/// decoded a second time on the UI isolate just to find them.
class GmailFullMessage {
  const GmailFullMessage({
    required this.email,
    required this.icsAttachmentId,
    required this.pendingInline,
  });

  final EmailModel email;

  /// Attachment id of a calendar part whose content was not inlined, or null
  /// when there is none or the ICS was already inlined into [email].
  final String? icsAttachmentId;

  /// Inline images that still need their own attachment fetch.
  final List<GmailPendingInline> pendingInline;
}

/// An inline image Gmail declared but did not inline.
class GmailPendingInline {
  const GmailPendingInline({
    required this.attachmentId,
    required this.contentId,
    required this.contentType,
  });

  final String attachmentId;
  final String contentId;
  final String contentType;
}

/// Parses one `format=full` message body. `compute()` entry point.
GmailFullMessage parseGmailFullMessage(String rawJson) {
  final json = jsonDecode(rawJson) as Map<String, dynamic>;
  final email = _parseMessage(json, fullBody: true);
  final payload = json['payload'] as Map<String, dynamic>? ?? {};

  final icsAttachmentId = email.meetingInvite == null
      ? _findIcsAttachmentId(payload)
      : null;

  final pendingInline = <GmailPendingInline>[];
  for (final a in _extractAttachments(payload, _referencedCids(email.body))) {
    if (a.isInline &&
        a.contentId != null &&
        a.attachmentId.isNotEmpty &&
        a.inlineData == null) {
      pendingInline.add(GmailPendingInline(
        attachmentId: a.attachmentId,
        contentId: a.contentId!,
        contentType: a.contentType,
      ));
    }
  }

  return GmailFullMessage(
    email: email,
    icsAttachmentId: icsAttachmentId,
    pendingInline: pendingInline,
  );
}

/// Inputs for [parseGmailThreads].
class GmailThreadParseParams {
  const GmailThreadParseParams({
    required this.rawThreadBodies,
    required this.excludeLabels,
  });

  /// Undecoded `/threads/{id}` response bodies. A null entry is a thread whose
  /// fetch failed and is simply skipped, so the caller can keep the list
  /// positional without filtering first.
  final List<String?> rawThreadBodies;

  /// Labels whose messages must not be re-cached under the folder being
  /// listed — `TRASH`/`SPAM` when listing anything else.
  final Set<String> excludeLabels;
}

/// Parses a whole page of thread responses in one go. `compute()` entry point.
///
/// Deliberately batched rather than one call per thread: `compute()` spawns an
/// isolate per invocation, and a 25-thread page would pay that 25 times over —
/// enough setup cost to lose most of what moving the work saved.
List<EmailModel> parseGmailThreads(GmailThreadParseParams params) {
  final out = <EmailModel>[];
  for (final raw in params.rawThreadBodies) {
    if (raw == null) continue;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      var messages =
          (data['messages'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      if (params.excludeLabels.isNotEmpty) {
        messages = messages.where((m) {
          final labels = (m['labelIds'] as List<dynamic>? ?? []).cast<String>();
          return !labels.any(params.excludeLabels.contains);
        }).toList();
      }
      for (final m in messages) {
        out.add(_parseMessage(m, fullBody: false));
      }
    } catch (_) {
      // One malformed thread must not lose the rest of the page.
    }
  }
  return out;
}

/// Parses a batch of metadata-only single-message bodies (the search path).
/// `compute()` entry point.
List<EmailModel> parseGmailMetadataMessages(List<String?> rawBodies) {
  final out = <EmailModel>[];
  for (final raw in rawBodies) {
    if (raw == null) continue;
    try {
      out.add(_parseMessage(
        jsonDecode(raw) as Map<String, dynamic>,
        fullBody: false,
      ));
    } catch (_) {
      // Skip the one that failed, keep the rest.
    }
  }
  return out;
}

/// Decodes an `/attachments/{id}` response body to bytes. `compute()` entry
/// point — base64 of a multi-megabyte image is exactly the kind of synchronous
/// work that must not run on the UI isolate.
Uint8List? decodeGmailAttachmentBytes(String rawJson) {
  try {
    final data = (jsonDecode(rawJson) as Map<String, dynamic>)['data'] as String?;
    if (data == null || data.isEmpty) return null;
    return base64Url.decode(padGmailBase64(data));
  } catch (_) {
    return null;
  }
}

/// Decodes an `/attachments/{id}` response holding an ICS part and turns it
/// into a [MeetingInvite]. `compute()` entry point.
MeetingInvite? parseGmailIcsAttachment(String rawJson) {
  try {
    final data = (jsonDecode(rawJson) as Map<String, dynamic>)['data'] as String?;
    if (data == null || data.isEmpty) return null;
    final icsStr = utf8.decode(base64Url.decode(padGmailBase64(data)));
    return buildMeetingInviteFromIcs(icsStr);
  } catch (_) {
    return null;
  }
}

/// What the forward path needs out of a `format=full` fetch: enough to build
/// the outgoing message, without decoding the payload on the UI isolate just to
/// read three fields off it.
class GmailForwardSource {
  const GmailForwardSource({
    required this.threadId,
    required this.subject,
    required this.attachments,
  });

  final String? threadId;
  final String subject;

  /// Downloadable (non-inline) attachments that can be re-attached.
  final List<GmailForwardAttachment> attachments;
}

/// An attachment carried forward onto a forwarded message.
class GmailForwardAttachment {
  const GmailForwardAttachment({
    required this.attachmentId,
    required this.name,
    required this.contentType,
  });

  final String attachmentId;
  final String name;
  final String contentType;
}

/// Parses the source message of a forward. `compute()` entry point.
GmailForwardSource parseGmailForwardSource(String rawJson) {
  final json = jsonDecode(rawJson) as Map<String, dynamic>;
  final payload = json['payload'] as Map<String, dynamic>? ?? {};
  final headers =
      (payload['headers'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  final subject = headers
      .firstWhere(
        (h) => (h['name'] as String).toLowerCase() == 'subject',
        orElse: () => {'value': ''},
      )['value'] as String;

  final attachments = <GmailForwardAttachment>[];
  for (final a in _extractAttachments(payload)) {
    if (a.isInline || a.attachmentId.isEmpty) continue;
    attachments.add(GmailForwardAttachment(
      attachmentId: a.attachmentId,
      name: a.name,
      contentType: a.contentType,
    ));
  }

  return GmailForwardSource(
    threadId: json['threadId'] as String?,
    subject: subject,
    attachments: attachments,
  );
}

/// Gmail's base64url payloads arrive without padding.
String padGmailBase64(String s) {
  final padding = (4 - s.length % 4) % 4;
  return s + ('=' * padding);
}

// ---------------------------------------------------------------------------
// Message parsing
// ---------------------------------------------------------------------------

EmailModel _parseMessage(Map<String, dynamic> json, {required bool fullBody}) {
  final id = json['id'] as String;
  final threadId = json['threadId'] as String?;
  final labelIds = (json['labelIds'] as List<dynamic>? ?? []).cast<String>();
  final isRead = !labelIds.contains('UNREAD');
  // STARRED is Gmail's flag, read the same way UNREAD is: it is a label, but a
  // hidden one that never becomes a folder (see [isHiddenGmailSystemLabel]), so
  // dropping it from [folderIds] below is what makes it a bit rather than a
  // place.
  final isFlagged = labelIds.contains('STARRED');
  final snippet = decodeHtmlEntities(json['snippet'] as String? ?? '');

  final payload = json['payload'] as Map<String, dynamic>? ?? {};
  final headers =
      (payload['headers'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

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
    if (icsData != null) meetingInvite = buildMeetingInviteFromIcs(icsData);

    final parsed = _extractAttachments(payload, _referencedCids(body));
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
              contentBytes: base64Url.decode(padGmailBase64(a.inlineData!)),
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

  // Gmail labels *are* this account's folder ids, and a message carries every
  // one it belongs to — which is what lets a folder-scoped action tell a
  // thread's in-folder messages from the copies (Sent, already-filed replies)
  // the Threads API returns alongside them. Hidden system labels are dropped
  // so this matches the ids getFolders() exposes; the resulting list may well
  // be longer than one, so it says strictly more than [parentFolderId].
  final folderIds =
      labelIds.where((l) => !isHiddenGmailSystemLabel(l)).toList();

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
    isFlagged: isFlagged,
    receivedDateTime: receivedAt,
    importance: EmailImportance.normal,
    parentFolderId: parentFolderId,
    folderIds: folderIds,
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
      final decoded = utf8.decode(base64Url.decode(padGmailBase64(data)));
      return (
        decoded,
        mimeType == 'text/html' ? EmailBodyType.html : EmailBodyType.text
      );
    }
  }

  // Multipart: prefer HTML part.
  final parts =
      (payload['parts'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

  String? htmlBody;
  String? textBody;

  void scanParts(List<Map<String, dynamic>> partList) {
    for (final part in partList) {
      final mt = part['mimeType'] as String? ?? '';
      if (mt == 'text/html') {
        final data =
            (part['body'] as Map<String, dynamic>?)?['data'] as String?;
        if (data != null) {
          htmlBody = utf8.decode(base64Url.decode(padGmailBase64(data)));
        }
      } else if (mt == 'text/plain' && htmlBody == null) {
        final data =
            (part['body'] as Map<String, dynamic>?)?['data'] as String?;
        if (data != null) {
          textBody = utf8.decode(base64Url.decode(padGmailBase64(data)));
        }
      } else if (mt.startsWith('multipart/')) {
        final nested =
            (part['parts'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
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
String? _extractIcsData(Map<String, dynamic> payload) {
  final mimeType = (payload['mimeType'] as String? ?? '').toLowerCase();
  final filename = (payload['filename'] as String? ?? '').toLowerCase();
  // Match on MIME type or .ics filename — some senders use application/octet-stream.
  if (mimeType == 'text/calendar' ||
      mimeType == 'application/ics' ||
      filename.endsWith('.ics')) {
    final data = (payload['body'] as Map<String, dynamic>?)?['data'] as String?;
    if (data != null && data.isNotEmpty) {
      return utf8.decode(base64Url.decode(padGmailBase64(data)));
    }
  }
  final parts =
      (payload['parts'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
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
  if (mimeType == 'text/calendar' ||
      mimeType == 'application/ics' ||
      filename.endsWith('.ics')) {
    final body = payload['body'] as Map<String, dynamic>?;
    final data = body?['data'] as String?;
    if (data != null && data.isNotEmpty) return null; // already inlined
    final attachmentId = body?['attachmentId'] as String?;
    if (attachmentId != null && attachmentId.isNotEmpty) return attachmentId;
  }
  final parts =
      (payload['parts'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  for (final part in parts) {
    final result = _findIcsAttachmentId(part);
    if (result != null) return result;
  }
  return null;
}

bool _detectAttachments(Map<String, dynamic> payload) {
  final filename = payload['filename'] as String? ?? '';
  if (filename.isNotEmpty) return true;

  final parts =
      (payload['parts'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  for (final part in parts) {
    if (_detectAttachments(part)) return true;
  }
  return false;
}

List<_GmailAttachment> _extractAttachments(Map<String, dynamic> payload,
    [Set<String>? referencedCids]) {
  final results = <_GmailAttachment>[];
  _collectAttachmentParts(payload, results, referencedCids);
  return results;
}

/// Bare cid tokens (without angle brackets) referenced by `cid:` in [body].
/// Gmail tags pasted inline images with `Content-Disposition: attachment`
/// even though the HTML references them inline via cid:, so the reference
/// set — not the disposition — is what decides whether a part is inline.
Set<String> _referencedCids(String body) {
  if (body.isEmpty) return const {};
  final ids = <String>{};
  for (final m
      in RegExp(r'''cid:([^"'\s>)\]]+)''', caseSensitive: false).allMatches(body)) {
    final id = m.group(1);
    if (id != null && id.isNotEmpty) ids.add(id);
  }
  return ids;
}

String _bareCid(String contentId) =>
    contentId.startsWith('<') && contentId.endsWith('>')
        ? contentId.substring(1, contentId.length - 1)
        : contentId;

/// Whether a part's bare Content-Id is referenced by the body. Gmail
/// sometimes emits `Content-ID: <ii_x@mail.gmail.com>` while the body
/// references only `cid:ii_x`, so fall back to comparing the local part
/// before any `@`.
bool _cidReferenced(String bareCid, Set<String> referenced) {
  if (referenced.contains(bareCid)) return true;
  final key = _cidLocalPart(bareCid);
  for (final r in referenced) {
    if (_cidLocalPart(r) == key) return true;
  }
  return false;
}

String _cidLocalPart(String cid) {
  final at = cid.indexOf('@');
  return at == -1 ? cid : cid.substring(0, at);
}

void _collectAttachmentParts(
    Map<String, dynamic> part, List<_GmailAttachment> out,
    [Set<String>? referencedCids]) {
  final filename = (part['filename'] as String? ?? '').trim();
  final headers =
      (part['headers'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

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

  // A part is worth extracting if it has a filename (a normal attachment)
  // or a Content-Id (an inline image referenced by cid:) — Gmail hoists
  // inline images embedded as data: URIs into their own part without ever
  // assigning a filename, so filename alone isn't a reliable signal.
  if (filename.isNotEmpty || contentId != null) {
    final mimeType = part['mimeType'] as String? ?? 'application/octet-stream';
    final body = part['body'] as Map<String, dynamic>? ?? {};
    final attachmentId = body['attachmentId'] as String? ?? '';
    final inlineData = body['data'] as String?;
    final size = body['size'] as int? ?? 0;

    // Gmail marks pasted inline images with `Content-Disposition: attachment`
    // while still referencing them via cid: in the HTML body. When the body's
    // cid references are known, treat a part as inline iff its Content-Id is
    // actually referenced (disposition is unreliable); otherwise fall back to
    // the disposition heuristic. Unreferenced Content-Id parts stay as
    // downloadable attachments.
    final bareCid = contentId == null ? null : _bareCid(contentId);
    final isInline = referencedCids != null
        ? (bareCid != null && _cidReferenced(bareCid, referencedCids))
        : (contentId != null && !hasAttachmentDisposition);
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

  final subParts =
      (part['parts'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  for (final sub in subParts) {
    _collectAttachmentParts(sub, out, referencedCids);
  }
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

/// Labels that are Gmail plumbing rather than folders: they are dropped both
/// from a message's reported folder membership and from the folder listing, so
/// the two agree on what ids exist. Public because the folder listing needs it
/// too, and it must stay the same set in both places.
bool isHiddenGmailSystemLabel(String id) {
  const hidden = {'CHAT', 'STARRED', 'IMPORTANT', 'UNREAD'};
  return hidden.contains(id);
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
