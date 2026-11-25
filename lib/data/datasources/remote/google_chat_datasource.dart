import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/chat.dart';
import 'chat_remote_datasource.dart';
import 'chat_images.dart';

/// Google Chat (`chat.googleapis.com/v1`) as the signed-in Workspace user.
///
/// Spaces map onto chats: `DIRECT_MESSAGE` is a one-on-one, `GROUP_CHAT` a
/// group, a named `SPACE` its own kind — threaded when its
/// `spaceThreadingState` says so, which is when posts and replies apply.
/// Google has no message search a user can call (`spaces.search` is for
/// administrators), so [searchesOnServer] is false. See `docs/claude/chat.md`.
class GoogleChatDatasource implements ChatRemoteDatasource {
  GoogleChatDatasource({required this._dio, required this.ownEmail});

  final Dio _dio;
  final String ownEmail;

  /// Names of direct messages and unnamed group chats, by space — a space's
  /// members do not change its title often enough to ask on every listing.
  static final _titles = <String, String>{};

  /// The signed-in user's `users/{id}`, by address: what tells "me" apart
  /// from the other person in a direct message's members.
  static final _ownIds = <String, String>{};

  /// How many direct messages and group chats get their members looked up
  /// per listing — the most recent ones; the rest keep a placeholder title
  /// until they are among them.
  static const _titledPerListing = 60;

  @override
  bool get searchesOnServer => false;

  @override
  bool get findsOneOnOneDirectly => true;

  @override
  Future<List<ChatConversation>> listChats() async {
    final raw = <Map<String, dynamic>>[];
    String? token;
    for (var page = 0; page < 3; page++) {
      final data = await _get('/spaces', query: {
        'pageSize': 1000,
        'pageToken': ?token,
      });
      raw.addAll(_list(data['spaces']));
      token = data['nextPageToken'] as String?;
      if (token == null || token.isEmpty) break;
    }
    raw.sort((a, b) => (b['lastActiveTime'] as String? ?? '')
        .compareTo(a['lastActiveTime'] as String? ?? ''));

    final untitled = raw
        .where((s) =>
            (s['spaceType'] == 'DIRECT_MESSAGE' ||
                (s['displayName'] as String? ?? '').isEmpty) &&
            !_titles.containsKey(s['name']))
        .take(_titledPerListing)
        .toList();
    if (untitled.isNotEmpty) {
      final own = await _ownUserId(untitled.first['name'] as String);
      for (var i = 0; i < untitled.length; i += 4) {
        await Future.wait(untitled.skip(i).take(4).map((s) async {
          try {
            _titles[s['name'] as String] =
                await _titleFromMembers(s['name'] as String, own);
          } on ServerException {
            // Untitled is better than no list.
          }
        }));
      }
    }
    return [for (final s in raw) ?_parseSpace(s)];
  }

  /// Whether each space was unread when it was last asked, by
  /// `ownEmail|space`, with the `lastActiveTime` it was asked at — a poll
  /// asks Google again only about a space something has happened in.
  static final _readStates = <String, ({String active, bool unread})>{};

  /// How many of the most recently active spaces the unread poll checks.
  static const _unreadChecked = 20;

  @visibleForTesting
  static void forgetIdentities() {
    _readStates.clear();
    _ownIds.clear();
  }

  /// The most recent spaces with their unread state. Google's `spaces.list`
  /// carries no read state, so a space that moved since the last poll costs
  /// its `spaceReadState` and, when that is behind, its newest message — to
  /// tell someone else's message from the user's own. A quiet poll is the one
  /// listing.
  @override
  Future<List<ChatConversation>> listRecentChats() async {
    final data = await _get('/spaces', query: {'pageSize': 1000});
    final raw = _list(data['spaces'])
      ..sort((a, b) => (b['lastActiveTime'] as String? ?? '')
          .compareTo(a['lastActiveTime'] as String? ?? ''));
    final recent = raw
        .where((s) => s['name'] is String && s['lastActiveTime'] is String)
        .take(_unreadChecked)
        .toList();
    if (recent.isEmpty) return const [];
    final own = await _ownUserId(recent.first['name'] as String);
    if (own == null) return const [];

    final unread = <String, bool>{};
    for (var i = 0; i < recent.length; i += 4) {
      await Future.wait(recent.skip(i).take(4).map((s) async {
        final name = s['name'] as String;
        final active = s['lastActiveTime'] as String;
        final key = '${ownEmail.toLowerCase()}|$name';
        final known = _readStates[key];
        if (known != null && known.active == active) {
          unread[name] = known.unread;
          return;
        }
        try {
          final value = await _isUnread(name, active, own,
              direct: s['spaceType'] == 'DIRECT_MESSAGE');
          _readStates[key] = (active: active, unread: value);
          unread[name] = value;
        } on ServerException {
          // One space that cannot be asked leaves the rest counted.
        }
      }));
    }
    return [
      for (final s in recent)
        if (_parseSpace(s) case final c?)
          c.copyWith(unread: unread[c.id] ?? false),
    ];
  }

  /// A direct message has no name of its own; when its newest message is
  /// the other person's, that names it ([direct]).
  Future<bool> _isUnread(String space, String active, String own,
      {bool direct = false}) async {
    final state = await _get('/users/me/$space/spaceReadState');
    final read = _date(state['lastReadTime']);
    final last = _date(active);
    if (last == null || (read != null && !last.isAfter(read))) return false;
    final newest = _list((await _get('/$space/messages', query: {
      'pageSize': 1,
      'orderBy': 'createTime DESC',
    }))['messages']);
    final sender = newest.firstOrNull?['sender'];
    final from = sender is Map ? sender['name'] as String? : null;
    final senderName =
        sender is Map ? (sender['displayName'] as String?)?.trim() : null;
    if (direct &&
        from != null &&
        from != own &&
        senderName != null &&
        senderName.isNotEmpty) {
      _titles.putIfAbsent(space, () => senderName);
    }
    return from != null && from != own;
  }

  /// Google coerces a later time to the newest message's, so "now" marks
  /// every top-level message read (a thread's replies keep their own state).
  @override
  Future<void> markRead(ChatConversation chat) async {
    await _patch(
      '/users/me/${chat.id}/spaceReadState',
      {'lastReadTime': DateTime.now().toUtc().toIso8601String()},
      query: {'updateMask': 'lastReadTime'},
    );
    final key = '${ownEmail.toLowerCase()}|${chat.id}';
    final known = _readStates[key];
    if (known != null) _readStates[key] = (active: known.active, unread: false);
  }

  @override
  Future<String?> ownUserId(ChatConversation? conversation) async =>
      _ownIds[ownEmail.toLowerCase()] ??
      (conversation == null || conversation.id.isEmpty
          ? null
          : await _ownUserId(conversation.id));

  @override
  Future<List<ChatConversation>> listChannels() async => const [];

  @override
  Future<ChatConversation> channelActivity(ChatConversation channel) async =>
      channel;

  @override
  Future<ChatConversation?> findOneOnOne(String email) async {
    try {
      final data = await _get('/spaces:findDirectMessage',
          query: {'name': 'users/$email'});
      final space = _parseSpace(data);
      return space == null
          ? null
          : ChatConversation(
              id: space.id,
              kind: ChatKind.oneOnOne,
              title: _titles[space.id] ?? email,
              lastActivity: space.lastActivity,
            );
    } on ServerException catch (e) {
      // Google's answer for "there is no direct message with them yet".
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// A threaded space's page is posts and replies together, newest first, so
  /// one busy thread can fill it with replies alone. Pages are read on until
  /// there are this many posts (or [_maxThreadedPages] pages) — an empty
  /// history with older posts behind it would read as an empty space.
  static const _minPosts = 10;
  static const _maxThreadedPages = 4;

  @override
  Future<ChatMessagePage> messages(
    ChatConversation conversation, {
    String? cursor,
  }) async {
    final rawMessages = <Map<String, dynamic>>[];
    String? next = cursor;
    for (var page = 0; page < _maxThreadedPages; page++) {
      final data = await _get('/${conversation.id}/messages', query: {
        'pageSize': 50,
        // Google's reference: ordering is `ASC`/`DESC` on createTime, whose
        // default it writes as "createTime ASC".
        'orderBy': 'createTime DESC',
        'showDeleted': true,
        'pageToken': ?next,
      });
      rawMessages.addAll(_list(data['messages']));
      final token = data['nextPageToken'] as String?;
      next = token == null || token.isEmpty ? null : token;
      if (next == null || !conversation.hasThreads) break;
      final posts =
          rawMessages.where((m) => m['threadReply'] != true).length;
      if (posts >= _minPosts) break;
    }
    final all = rawMessages.map(_parseMessage).toList();

    final List<ChatMessage> messages;
    if (!conversation.hasThreads) {
      messages = all;
    } else {
      // A threaded space lists posts and replies together: the replies on
      // this page are attached to their post, the posts are the history.
      final replies = <String, List<ChatMessage>>{};
      final rawById = {for (final m in rawMessages) m['name'] as String?: m};
      for (final m in all) {
        if (rawById[m.id]?['threadReply'] == true && m.threadId != null) {
          replies.putIfAbsent(m.threadId!, () => []).add(m);
        }
      }
      messages = [
        for (final m in all)
          if (rawById[m.id]?['threadReply'] != true)
            _withReplies(m, [...?replies[m.threadId]]
              ..sort((a, b) => a.createdAt.compareTo(b.createdAt))),
      ];
    }
    messages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return ChatMessagePage(messages: messages, nextLink: next);
  }

  /// Messages created since [since] (`filter=createTime > …`). Edits and
  /// reactions do not show, so the repository still reads a full page now
  /// and then. A threaded space lists replies as messages of their own,
  /// which belong under posts this cannot see: null, a full page.
  @override
  Future<ChatMessageDelta?> messagesSince(
      ChatConversation conversation, DateTime since) async {
    if (conversation.hasThreads) return null;
    final data = await _get('/${conversation.id}/messages', query: {
      'pageSize': 50,
      'orderBy': 'createTime DESC',
      'filter': 'createTime > "${since.toUtc().toIso8601String()}"',
    });
    // A full page may have more behind it: not a delta to trust.
    final token = data['nextPageToken'] as String?;
    if (token != null && token.isNotEmpty) return null;
    final messages = _list(data['messages']).map(_parseMessage).toList();
    return ChatMessageDelta(
      messages: messages,
      watermark: messages
          .map((m) => m.createdAt)
          .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a),
    );
  }

  @override
  Future<List<ChatMessage>> replies(
    ChatConversation conversation,
    ChatMessage post,
  ) async {
    final thread = post.threadId;
    if (thread == null) return const [];
    final data = await _get('/${conversation.id}/messages', query: {
      'pageSize': 1000,
      'orderBy': 'createTime ASC',
      // Unquoted, as in Google's own example; only timestamps are quoted.
      'filter': 'thread.name = $thread',
    });
    return [
      for (final m in _list(data['messages']))
        if (m['name'] != post.id) _parseMessage(m),
    ];
  }

  @override
  Future<ChatMessage> send(
    ChatConversation conversation,
    String text, {
    ChatMessage? replyTo,
  }) async {
    final thread = replyTo?.threadId;
    final data = await _post(
      '/${conversation.id}/messages',
      {
        'text': text,
        if (thread != null) 'thread': {'name': thread},
      },
      query: {
        if (thread != null)
          'messageReplyOption': 'REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD',
      },
    );
    return _parseMessage(data);
  }

  @override
  bool canEdit(ChatConversation conversation) => true;

  /// `spaces.patch` wants `chat.spaces`, which `GmailAuthService.chatScopes`
  /// leaves out on purpose (`chat.spaces.create` starts a DM without power
  /// to rename or delete spaces).
  @override
  bool canRename(ChatConversation conversation) => false;

  @override
  Future<ChatConversation> rename(
          ChatConversation conversation, String title) =>
      throw UnsupportedError('Google Chat spaces are not renamed here');

  /// `messages.patch` of the text alone; pictures and the thread stay.
  @override
  Future<ChatMessage> edit(
    ChatConversation conversation,
    ChatMessage message,
    String text,
  ) async {
    final data = await _patch(
      '/${message.id}',
      {'text': text},
      query: {'updateMask': 'text'},
    );
    final echoed = data['name'] is String ? _parseMessage(data) : null;
    return message.withEdit(
      bodyHtml: echoed?.bodyHtml ?? chatTextToHtml(text),
      editableText: text,
      editedAt: echoed?.editedAt ?? DateTime.now(),
    );
  }

  /// `reactions.create`, under the `chat.messages` NightMail already holds.
  @override
  bool canReact(ChatConversation conversation) => true;

  /// A repeat is taken to answer 409 (`ALREADY_EXISTS`): the reaction is
  /// there, just not a new one — the summaries Google lists name no one, so
  /// the server is the only one who can tell. Google does not document the
  /// repeat; should it answer 200 instead, the count shows one high until
  /// the next read of the page.
  @override
  Future<bool> react(
    ChatConversation conversation,
    ChatMessage message,
    String emoji,
  ) async {
    try {
      await _post('/${message.id}/reactions', {
        'emoji': {'unicode': emoji},
      });
      return true;
    } on ServerException catch (e) {
      if (e.statusCode == 409) return false;
      rethrow;
    }
  }

  /// `spaces.setup` returns the existing direct message when there is one.
  @override
  Future<ChatConversation> createOneOnOne({
    required String ownEmail,
    required String email,
    required String displayName,
  }) async {
    final data = await _post('/spaces:setup', {
      'space': {'spaceType': 'DIRECT_MESSAGE', 'singleUserBotDm': false},
      'memberships': [
        {
          'member': {'name': 'users/$email', 'type': 'HUMAN'},
        },
      ],
    });
    final id = data['name'] as String? ?? '';
    final title = displayName.isNotEmpty ? displayName : email;
    _titles[id] = title;
    return ChatConversation(
      id: id,
      kind: ChatKind.oneOnOne,
      title: title,
      lastActivity: DateTime.now(),
    );
  }

  @override
  Future<Set<String>?> directoryMembers(List<String> emails) async => null;

  @override
  Future<List<ChatSearchHit>> search(String query) =>
      throw UnsupportedError('Google Chat has no user message search');

  // ---- parsing ------------------------------------------------------------

  ChatConversation? _parseSpace(Map<String, dynamic> raw) {
    final id = raw['name'] as String?;
    if (id == null) return null;
    final type = raw['spaceType'] as String? ??
        (raw['singleUserBotDm'] == true ? 'DIRECT_MESSAGE' : 'SPACE');
    final kind = switch (type) {
      'DIRECT_MESSAGE' => ChatKind.oneOnOne,
      'GROUP_CHAT' => ChatKind.group,
      _ => ChatKind.space,
    };
    final named = (raw['displayName'] as String? ?? '').trim();
    final threading = raw['spaceThreadingState'] as String?;
    return ChatConversation(
      id: id,
      kind: kind,
      title: named.isNotEmpty
          ? named
          : _titles[id] ??
              (kind == ChatKind.oneOnOne ? 'Direct message' : 'Group chat'),
      lastActivity: _date(raw['lastActiveTime']) ?? _date(raw['createTime']),
      // "Timestamp of the last message in the space": none, no messages.
      noMessages: raw['lastActiveTime'] == null,
      threaded: kind == ChatKind.space &&
          (threading == 'THREADED_MESSAGES' || threading == 'GROUPED_MESSAGES'),
    );
  }

  ChatMessage _parseMessage(Map<String, dynamic> raw) {
    final sender = raw['sender'];
    final thread = raw['thread'];
    return ChatMessage(
      id: raw['name'] as String? ?? '',
      createdAt: _date(raw['createTime']) ?? DateTime.now(),
      senderName:
          (sender is Map ? sender['displayName'] as String? : null) ?? '',
      senderUserId: sender is Map ? sender['name'] as String? : null,
      bodyHtml: chatTextToHtml(raw['text'] as String? ?? '') +
          _imagesHtml(raw['attachment']),
      editedAt: _date(raw['lastUpdateTime']),
      isDeleted: raw['deleteTime'] != null,
      threadId: thread is Map ? thread['name'] as String? : null,
      editableText: editableTextOf(raw),
      reactions: [
        for (final r in _list(raw['emojiReactionSummaries']))
          if (r['emoji'] is Map &&
              ((r['emoji'] as Map)['unicode'] as String?)?.isNotEmpty == true)
            ChatReaction(
              emoji: (r['emoji'] as Map)['unicode'] as String,
              count: (r['reactionCount'] as num?)?.toInt() ?? 1,
            ),
      ],
      attachmentNames: [
        for (final a in _list(raw['attachment']))
          if ((a['contentName'] as String?)?.isNotEmpty == true &&
              _mediaRef(a) == null)
            a['contentName'] as String,
      ],
    );
  }

  /// The scheme of an `<img src>` this datasource writes for an uploaded
  /// picture: the attachment's `attachmentDataRef.resourceName`, which only
  /// `media/{resourceName}?alt=media` downloads, with the user's token.
  static const mediaScheme = 'gchat-media';

  /// An uploaded image attachment's resource name; null for anything else,
  /// including a Drive file (which stays a named attachment).
  static String? _mediaRef(Map<String, dynamic> a) {
    final type = a['contentType'] as String? ?? '';
    final ref = a['attachmentDataRef'];
    if (!type.startsWith('image/') || ref is! Map) return null;
    final name = ref['resourceName'] as String?;
    return name == null || name.isEmpty ? null : name;
  }

  /// Uploaded pictures, after the text, as images the renderer loads through
  /// [image].
  static String _imagesHtml(Object? attachments) {
    final out = StringBuffer();
    for (final a in _list(attachments)) {
      final ref = _mediaRef(a);
      if (ref == null) continue;
      final alt = (a['contentName'] as String? ?? '')
          .replaceAll('&', '&amp;')
          .replaceAll('"', '&quot;')
          .replaceAll('<', '&lt;');
      out.write('<p><img src="$mediaScheme:${Uri.encodeComponent(ref)}" '
          'alt="$alt"></p>');
    }
    return out.toString();
  }

  static ChatMessage _withReplies(ChatMessage m, List<ChatMessage> replies) =>
      ChatMessage(
        id: m.id,
        createdAt: m.createdAt,
        senderName: m.senderName,
        senderUserId: m.senderUserId,
        bodyHtml: m.bodyHtml,
        editedAt: m.editedAt,
        isDeleted: m.isDeleted,
        reactions: m.reactions,
        attachmentNames: m.attachmentNames,
        threadId: m.threadId,
        replies: replies,
      );

  @override
  Future<Uint8List?> image(String src) async {
    if (src.startsWith('$mediaScheme:')) {
      final ref = Uri.decodeComponent(src.substring(mediaScheme.length + 1));
      // A whole URL, not a path: Dio folds `//` in a relative path to `/`,
      // and a resource name is base64 that can contain it.
      return fetchImageBytes(_dio, '${_dio.options.baseUrl}/media/$ref',
          query: {'alt': 'media'});
    }
    final uri = Uri.tryParse(src);
    if (uri == null || uri.scheme != 'https') return null;
    return fetchImageBytes(publicImageClient, src);
  }

  /// A Chat user's `users/{id}` is their People API id, so the photo comes
  /// from `people/{id}` (the Workspace directory, `directory.readonly`) —
  /// asked with the same token, then fetched from Google's image host with
  /// none. Google's generated letter avatar (`default`) is skipped: the
  /// pane draws its own initials.
  @override
  Future<Uint8List?> photo(String userId) async {
    final id = userId.startsWith('users/') ? userId.substring(6) : userId;
    if (id.isEmpty || id == 'app') return null;
    try {
      final r = await _dio.get<Map<String, dynamic>>(
        'https://people.googleapis.com/v1/people/${Uri.encodeComponent(id)}',
        queryParameters: {'personFields': 'photos'},
      );
      final photos = _list(r.data?['photos']);
      final chosen = photos.where((p) => p['default'] != true).firstOrNull;
      final url = chosen?['url'] as String?;
      final uri = url == null ? null : Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          !uri.host.endsWith('.googleusercontent.com')) {
        return null;
      }
      // Google's photo URLs end in a size directive; ask for 64 pixels.
      final sized = url!.replaceFirst(RegExp(r'=s\d+(-c)?$'), '=s64-c');
      return await fetchImageBytes(publicImageClient, sized);
    } catch (_) {
      return null;
    }
  }

  /// A message's `text` to edit, or null when plain text would lose part of
  /// it: an annotation (a read mention is `@Name` in `text` with a
  /// `USER_MENTION` annotation over it; a Drive chip or custom emoji is one
  /// too), a card, or Chat's `<users/…>`/`<url|label>` markup the edit box
  /// would show raw.
  @visibleForTesting
  static String? editableTextOf(Map<String, dynamic> raw) {
    final text = raw['text'] as String? ?? '';
    if (text.trim().isEmpty ||
        _list(raw['annotations']).isNotEmpty ||
        _list(raw['cardsV2']).isNotEmpty ||
        _list(raw['cards']).isNotEmpty ||
        RegExp(r'<[^<>\s]+>').hasMatch(text)) {
      return null;
    }
    return text;
  }

  /// Google Chat's plain `text` as the HTML the chat renderer reads: escaped,
  /// line breaks kept, and Chat's own markup — `*bold*`, `_italic_`,
  /// `~strike~`, `` `code` `` — and bare links styled.
  static String chatTextToHtml(String text) {
    var html = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    html = html.replaceAllMapped(
        RegExp(r'`([^`\n]+)`'), (m) => '<code>${m[1]}</code>');
    html = html.replaceAllMapped(RegExp(r'(?<![\w*])\*([^*\n]+)\*(?![\w*])'),
        (m) => '<b>${m[1]}</b>');
    html = html.replaceAllMapped(
        RegExp(r'(?<![\w_])_([^_\n]+)_(?![\w_])'), (m) => '<i>${m[1]}</i>');
    html = html.replaceAllMapped(
        RegExp(r'(?<![\w~])~([^~\n]+)~(?![\w~])'), (m) => '<s>${m[1]}</s>');
    html = html.replaceAllMapped(RegExp(r'https?://[^\s<]+'),
        (m) => '<a href="${m[0]}">${m[0]}</a>');
    return html.replaceAll('\n', '<br>');
  }

  Future<String?> _ownUserId(String anySpace) async {
    final cached = _ownIds[ownEmail.toLowerCase()];
    if (cached != null) return cached;
    try {
      // With user auth a membership can be named by the member's address.
      final data = await _get('/$anySpace/members/$ownEmail');
      final member = data['member'];
      final id = member is Map ? member['name'] as String? : null;
      if (id != null) _ownIds[ownEmail.toLowerCase()] = id;
      return id;
    } on ServerException {
      return null;
    }
  }

  Future<String> _titleFromMembers(String space, String? ownId) async {
    final data = await _get('/$space/members', query: {'pageSize': 20});
    final names = [
      for (final m in _list(data['memberships']))
        if (m['member'] is Map &&
            (m['member'] as Map)['type'] == 'HUMAN' &&
            (m['member'] as Map)['name'] != ownId)
          ((m['member'] as Map)['displayName'] as String? ?? '').trim(),
    ].where((n) => n.isNotEmpty).toList();
    if (names.isEmpty) throw const ServerException(message: 'No members');
    return names.join(', ');
  }

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  static List<Map<String, dynamic>> _list(Object? v) => v is List
      ? v.whereType<Map<String, dynamic>>().toList()
      : const [];

  // ---- transport ----------------------------------------------------------

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final r =
          await _dio.get<Map<String, dynamic>>(path, queryParameters: query);
      return r.data ?? const {};
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(path,
          data: body, queryParameters: query);
      return r.data ?? const {};
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  Future<Map<String, dynamic>> _patch(
    String path,
    Map<String, dynamic> body, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await _dio.patch<Map<String, dynamic>>(path,
          data: body, queryParameters: query);
      return r.data ?? const {};
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  static Exception _map(DioException e) {
    if (e.error is AuthException) return e.error as AuthException;
    if (e.error is NetworkException) return e.error as NetworkException;
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return NetworkException(message: e.message ?? 'Network error');
    }
    final status = e.response?.statusCode;
    final data = e.response?.data;
    var message = data is Map && data['error'] is Map
        ? (data['error'] as Map)['message'] as String?
        : null;
    if (status == 401) {
      return AuthException(message: message ?? 'Authentication required');
    }
    // The Chat API answers every call with this until the Cloud project has
    // a Chat app configured — a setup step, not something the user did.
    if (message != null && message.contains('Chat app not found')) {
      message = 'Google Chat is not set up for NightMail yet: the Google '
          'Cloud project needs the Chat API enabled and a Chat app '
          'configured.';
    }
    return ServerException(
      message: message ??
          (status != null ? 'Server error ($status)' : 'Unknown server error'),
      statusCode: status,
    );
  }
}
