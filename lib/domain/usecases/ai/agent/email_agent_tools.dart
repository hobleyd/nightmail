import 'dart:convert';

import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';
import '../../../../core/usecases/usecase.dart';
import '../../../entities/email.dart';
import '../../../entities/email_address.dart';
import '../../../entities/email_folder.dart';
import '../../get_email.dart';
import '../../get_emails.dart';
import '../../get_mail_folders.dart';
import '../../search_emails.dart';
import 'agent_tool.dart';

/// `list_emails` — lists the emails in a folder (defaults to the current
/// folder), returning an indexed list of metadata + preview.
///
/// Backs [GetEmails]. Previews only (no full bodies), so it is unaffected by
/// the cloud-bodies privacy guard.
class ListEmailsTool implements AgentTool {
  const ListEmailsTool(this._getEmails);

  /// Emails returned when the model names no `limit`, and the most it may ask
  /// for. Shared with the card that replays the call in the email list.
  static const defaultLimit = 25;
  static const maxLimit = 100;

  final GetEmails _getEmails;

  @override
  String get name => 'list_emails';

  @override
  String get description =>
      'List emails in a folder (defaults to the folder the user is currently '
      'viewing). Returns an indexed list of id, from, subject, date, read '
      'state and a short preview. Use get_email to read a full message.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'folder_id': {
            'type': 'string',
            'description':
                'Folder to list from. Defaults to the current folder.',
          },
          'limit': {
            'type': 'integer',
            'description': 'Maximum emails to return (default 25, max 100).',
          },
          'unread_only': {
            'type': 'boolean',
            'description': 'When true, only return unread emails.',
          },
        },
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final folderId = _asString(args['folder_id']) ?? currentFolderId;
    final limit =
        ((_asInt(args['limit']) ?? defaultLimit).clamp(1, maxLimit)).toInt();
    final unreadOnly = _asBool(args['unread_only']) ?? false;

    final result = await _getEmails(
      GetEmailsParams(
        folderId: folderId,
        top: limit,
        filter: unreadOnly ? 'isRead eq false' : null,
      ),
    );
    return result.map(_encodeEmailList);
  }
}

/// `get_email` — reads a single email by id.
///
/// Backs [GetEmail]. The privacy guard (§4) lives here: when [includeBodies]
/// is false (cloud provider, user has not opted in), the full body is withheld
/// and only metadata + preview are returned, with a note explaining why.
class GetEmailTool implements AgentTool {
  const GetEmailTool(this._getEmail, {required this.includeBodies});

  final GetEmail _getEmail;

  /// Whether full message bodies may be returned. False = cloud provider
  /// without the cloud-bodies opt-in → return preview only.
  final bool includeBodies;

  @override
  String get name => 'get_email';

  @override
  String get description =>
      'Read a single email by its id, including recipients and the full body '
      'when permitted. Get ids from list_emails or search_emails first.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'description': 'The id of the email to read.',
          },
        },
        'required': ['id'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final id = _asString(args['id']);
    if (id == null) {
      return Right(jsonEncode({'error': "Missing required argument 'id'."}));
    }

    final result = await _getEmail(GetEmailParams(id: id));
    return result.map((email) => _encodeEmail(email, includeBodies));
  }
}

/// `search_emails` — full-text searches a folder (or the current folder).
///
/// Backs [SearchEmails]. Returns the same metadata + preview list shape as
/// [ListEmailsTool], so it is unaffected by the cloud-bodies guard.
class SearchEmailsTool implements AgentTool {
  const SearchEmailsTool(this._searchEmails);

  /// As [ListEmailsTool.defaultLimit] / [ListEmailsTool.maxLimit].
  static const defaultLimit = 50;
  static const maxLimit = 100;

  final SearchEmails _searchEmails;

  @override
  String get name => 'search_emails';

  @override
  String get description =>
      'Search for emails matching a query (defaults to the current folder). '
      'Returns an indexed list of id, from, subject, date, read state and a '
      'short preview. Use get_email to read a full message.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The search query.',
          },
          'folder_id': {
            'type': 'string',
            'description':
                'Folder to search. Defaults to the current folder.',
          },
          'limit': {
            'type': 'integer',
            'description': 'Maximum results to return (default 50, max 100).',
          },
        },
        'required': ['query'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final query = _asString(args['query']);
    if (query == null) {
      return Right(jsonEncode({'error': "Missing required argument 'query'."}));
    }
    final folderId = _asString(args['folder_id']) ?? currentFolderId;
    final limit =
        ((_asInt(args['limit']) ?? defaultLimit).clamp(1, maxLimit)).toInt();

    final result = await _searchEmails(
      SearchEmailsParams(query: query, folderId: folderId, top: limit),
    );
    return result.map(_encodeEmailList);
  }
}

/// `list_folders` — lists the user's mail folders with unread/total counts.
///
/// Backs [GetMailFolders]. Takes no arguments.
class ListFoldersTool implements AgentTool {
  const ListFoldersTool(this._getMailFolders);

  final GetMailFolders _getMailFolders;

  @override
  String get name => 'list_folders';

  @override
  String get description =>
      'List the user\'s mail folders with their unread and total message '
      'counts. Use a folder id with list_emails or search_emails.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': <String, dynamic>{},
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final result = await _getMailFolders(const NoParams());
    return result.map(_encodeFolderList);
  }
}

/// `show_emails` — names the emails that answer the user's request, once the
/// model has narrowed a search down by reading what it found.
///
/// A search card can only replay its query, so without this the model's pick
/// lives in its prose and the list cannot show it. Each id is read back, so an
/// id the model made up is dropped rather than shown; the output is the same
/// shape as a listing, which is what the card's "Show in list" reads.
class ShowEmailsTool implements AgentTool {
  const ShowEmailsTool(this._getEmail);

  /// The most ids one call may name; more are ignored.
  static const maxIds = 25;

  final GetEmail _getEmail;

  @override
  String get name => 'show_emails';

  @override
  String get description =>
      'Pick out the emails that answer the user\'s request so they can open '
      'them in their email list. Call this once, at the end, with the ids of '
      'the matching emails whenever the user asked to find emails and you '
      'narrowed a search or listing down — not for every email you looked at.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'ids': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Ids of the matching emails, from list_emails, '
                'search_emails or get_email (at most $maxIds).',
          },
          'title': {
            'type': 'string',
            'description': 'A few words naming what these emails are, e.g. '
                '"MacBook purchase, May".',
          },
        },
        'required': ['ids'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final raw = args['ids'];
    final ids = <String>{
      if (raw is List)
        for (final v in raw) ?_asString(v),
    }.take(maxIds).toList();
    if (ids.isEmpty) {
      return Right(jsonEncode({'error': "Missing required argument 'ids'."}));
    }

    final results =
        await Future.wait(ids.map((id) => _getEmail(GetEmailParams(id: id))));
    final found = <Email>[];
    final missing = <String>[];
    for (var i = 0; i < ids.length; i++) {
      results[i].fold((_) => missing.add(ids[i]), found.add);
    }
    if (found.isEmpty) {
      return Right(jsonEncode({
        'error': 'None of those ids is an email. Use ids exactly as '
            'list_emails, search_emails or get_email returned them.',
      }));
    }
    final listing = jsonDecode(_encodeEmailList(found)) as Map<String, dynamic>;
    return Right(jsonEncode({
      ...listing,
      if (missing.isNotEmpty) 'notFound': missing,
    }));
  }
}

// --- Shared formatting helpers -------------------------------------------

/// Encodes a list of emails as a compact indexed JSON string (metadata +
/// preview, no full bodies).
String _encodeEmailList(List<Email> emails) {
  final items = <Map<String, dynamic>>[];
  for (var i = 0; i < emails.length; i++) {
    final e = emails[i];
    items.add({
      'index': i,
      'id': e.id,
      'from': _formatAddress(e.from),
      'subject': e.subject,
      'date': e.receivedDateTime.toIso8601String(),
      'isRead': e.isRead,
      'hasAttachments': e.hasAttachments,
      'preview': e.bodyPreview,
    });
  }
  return jsonEncode({'count': items.length, 'emails': items});
}

/// Encodes a single email as a JSON string. The full [Email.body] is included
/// only when [includeBodies] is true; otherwise the preview is returned with a
/// note explaining the privacy guard.
String _encodeEmail(Email e, bool includeBodies) {
  final map = <String, dynamic>{
    'id': e.id,
    'from': _formatAddress(e.from),
    'to': e.toRecipients.map(_formatAddress).toList(),
    'cc': e.ccRecipients.map(_formatAddress).toList(),
    if (e.bccRecipients.isNotEmpty)
      'bcc': e.bccRecipients.map(_formatAddress).toList(),
    'subject': e.subject,
    'date': e.receivedDateTime.toIso8601String(),
    'isRead': e.isRead,
    'importance': e.importance.name,
    'hasAttachments': e.hasAttachments,
  };
  if (includeBodies) {
    map['bodyType'] = e.bodyType.name;
    map['body'] = e.body;
  } else {
    map['preview'] = e.bodyPreview;
    map['note'] = 'Full message body is disabled for cloud providers without '
        'explicit opt-in. Showing preview only.';
  }
  return jsonEncode(map);
}

/// Encodes mail folders as a compact JSON string.
String _encodeFolderList(List<EmailFolder> folders) {
  final items = folders
      .map((f) => {
            'id': f.id,
            'name': f.displayName,
            'unread': f.unreadItemCount,
            'total': f.totalItemCount,
          })
      .toList();
  return jsonEncode({'count': items.length, 'folders': items});
}

String _formatAddress(EmailAddress a) {
  final name = a.name;
  if (name != null && name.isNotEmpty) return '$name <${a.address}>';
  return a.address;
}

String? _asString(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

bool? _asBool(Object? v) {
  if (v is bool) return v;
  if (v is int) return v == 1 ? true : (v == 0 ? false : null);
  if (v is String) {
    switch (v.toLowerCase()) {
      case 'true':
      case '1':
        return true;
      case 'false':
      case '0':
        return false;
    }
  }
  return null;
}
