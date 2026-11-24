import 'package:dio/dio.dart';

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/chat.dart';
import 'chat_remote_datasource.dart';

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
      bodyHtml: chatTextToHtml(raw['text'] as String? ?? ''),
      editedAt: _date(raw['lastUpdateTime']),
      isDeleted: raw['deleteTime'] != null,
      threadId: thread is Map ? thread['name'] as String? : null,
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
          if ((a['contentName'] as String?)?.isNotEmpty == true)
            a['contentName'] as String,
      ],
    );
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
