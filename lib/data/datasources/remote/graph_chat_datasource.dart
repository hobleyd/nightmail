import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/error/exceptions.dart';
import '../../../core/utils/latest_reply.dart' show htmlToPlainText;
import '../../../domain/entities/chat.dart';
import 'chat_images.dart';
import 'chat_remote_datasource.dart';

/// Graph's chat and Teams-channel API, as Microsoft 365 and a NightMail
/// Server (Nextcloud Talk behind Graph's shapes, nightware ADR 0009) both
/// serve it. Always the signed-in user's own (`/me`) — a shared mailbox has
/// no chats, so the account manager hands this the credential owner's client.
///
/// Only what both servers accept is asked for: no `$filter` on `/me/chats`
/// (Nightware refuses one), `$orderby` only newest first, `$top` at most 50.
/// See `docs/claude/chat.md`.
class GraphChatDatasource implements ChatRemoteDatasource {
  GraphChatDatasource({
    required this._dio,
    required Set<String> ownAddresses,
    required this.isNightmailServer,
  }) : _own = ownAddresses;

  final Dio _dio;
  final Set<String> _own;
  final bool isNightmailServer;

  /// Microsoft Search; a NightMail Server has no search route.
  @override
  bool get searchesOnServer => !isNightmailServer;

  /// Neither server can filter `/me/chats` by member.
  @override
  bool get findsOneOnOneDirectly => false;

  @override
  Future<ChatConversation?> findOneOnOne(String email) =>
      throw UnsupportedError('Graph one-on-ones are found by listing chats');

  /// How many pages of `/me/chats` to read. 250 chats is far more than a
  /// list anybody scrolls; the rest are found by search.
  static const _maxChatPages = 5;

  /// Roots on which `/me/chats` refused both expansions in one request.
  /// Microsoft documents each of `members` and `lastMessagePreview` as
  /// expandable but shows them only one at a time; Nightware takes both.
  static final _splitExpandRoots = <String>{};

  /// The signed-in user's directory id, by [_identity]: `/me` once per
  /// session. Nightware names users by Keycloak id in `/me` and in a
  /// message's `from.user.id` alike (ADR 0009 D2), as Microsoft does by
  /// object id.
  static final _ownIds = <String, String>{};

  /// Microsoft's tenant id, by [_identity], for `markChatReadForUser`.
  static final _tenantIds = <String, String>{};

  /// Who this datasource acts as. Not the root alone: every Microsoft 365
  /// account shares Microsoft's Graph root, and every account on one
  /// NightMail Server shares its root — one account's id must never stand
  /// for another's.
  String get _identity => '${_root()}|${(_own.toList()..sort()).join(',')}';

  @visibleForTesting
  static void forgetIdentities() {
    _ownIds.clear();
    _tenantIds.clear();
  }

  /// Unread is marked only once the user's id is known ([listRecentChats]
  /// learns it); the full listing never asks `/me` for it.
  @override
  Future<List<ChatConversation>> listChats() async {
    final own = _ownIds[_identity];
    if (!_splitExpandRoots.contains(_root())) {
      try {
        return _parseChats(
            await _listChatPages('members,lastMessagePreview', ordered: true),
            own);
      } on ServerException catch (e) {
        if (e.statusCode != 400) rethrow;
        _splitExpandRoots.add(_root());
      }
    }
    // Two listings merged by id: the preview carries the activity the list
    // sorts by, the members carry the names a one-on-one is titled by.
    final previews =
        await _listChatPages('lastMessagePreview', ordered: true);
    final members = {
      for (final raw in await _listChatPages('members', ordered: false))
        if (raw['id'] is String) raw['id'] as String: raw['members'],
    };
    return _parseChats([
      for (final raw in previews)
        {...raw, if (members.containsKey(raw['id'])) 'members': members[raw['id']]},
    ], own);
  }

  List<ChatConversation> _parseChats(
    List<Map<String, dynamic>> raws,
    String? ownId,
  ) =>
      [
        for (final raw in raws) ?_parseChat(raw, ownId),
      ];

  /// One page of `/me/chats` with the preview alone — accepted on its own by
  /// both servers, so never the 400 split. Titles are rough without members;
  /// only [ChatConversation.unread] is read from it.
  @override
  Future<List<ChatConversation>> listRecentChats() async {
    final own = await ownUserId(null);
    if (own == null) return const [];
    final data = await _get('/me/chats', query: {
      r'$expand': 'lastMessagePreview',
      r'$orderby': 'lastMessagePreview/createdDateTime desc',
      r'$top': 50,
    });
    return _parseChats(_values(data), own);
  }

  /// Microsoft wants the reader as `{id, tenantId}`; Nightware takes the id
  /// alone (its contract, `chats.mark-read`).
  @override
  Future<void> markRead(ChatConversation chat) async {
    if (chat.isChannel) return;
    final own = await ownUserId(null);
    if (own == null) return;
    final tenant = isNightmailServer ? null : await _tenantId();
    await _post('/chats/${chat.id}/markChatReadForUser', {
      'user': {'id': own, 'tenantId': ?tenant},
    });
  }

  @override
  Future<String?> ownUserId(ChatConversation? conversation) async {
    final cached = _ownIds[_identity];
    if (cached != null) return cached;
    try {
      return _ownIds[_identity] = await _ownUserId();
    } on ServerException {
      return null;
    }
  }

  Future<String?> _tenantId() async {
    final cached = _tenantIds[_identity];
    if (cached != null) return cached;
    try {
      final orgs = _values(
          await _get('/organization', query: {r'$select': 'id'}));
      final id = orgs.firstOrNull?['id'];
      return id is String ? _tenantIds[_identity] = id : null;
    } on ServerException {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _listChatPages(
    String expand, {
    required bool ordered,
  }) async {
    final out = <Map<String, dynamic>>[];
    String? next = '/me/chats';
    Map<String, dynamic>? query = {
      r'$expand': expand,
      if (ordered) r'$orderby': 'lastMessagePreview/createdDateTime desc',
      r'$top': 50,
    };
    for (var page = 0; next != null && page < _maxChatPages; page++) {
      final data = await _get(next, query: query);
      query = null; // A nextLink carries its own.
      out.addAll(_values(data));
      next = _nextLink(data);
    }
    return out;
  }

  @override
  Future<List<ChatConversation>> listChannels() async {
    final teams = _values(await _get('/me/joinedTeams'));
    final channels = <ChatConversation>[];
    for (final team in teams) {
      final teamId = team['id'] as String?;
      if (teamId == null) continue;
      final teamName = (team['displayName'] as String?) ?? 'Team';
      final List<Map<String, dynamic>> raw;
      try {
        raw = _values(await _get('/teams/$teamId/channels'));
      } on ServerException catch (e) {
        // One team the user cannot list (archived, policy) must not hide the
        // rest of them.
        if (e.statusCode == 403 || e.statusCode == 404) continue;
        rethrow;
      }
      for (final c in raw) {
        final id = c['id'] as String?;
        if (id == null) continue;
        channels.add(ChatConversation(
          id: id,
          kind: ChatKind.channel,
          title: (c['displayName'] as String?) ?? 'Channel',
          teamId: teamId,
          teamName: teamName,
          lastActivity: _date(c['createdDateTime']),
        ));
      }
    }
    return channels;
  }

  /// The newest activity in a channel: a post's own time or its last reply's,
  /// which Graph reports as the post's `lastModifiedDateTime`.
  @override
  Future<ChatConversation> channelActivity(ChatConversation channel) async {
    final data = await _get(
      '/teams/${channel.teamId}/channels/${channel.id}/messages',
      query: {r'$top': 5},
    );
    DateTime? newest;
    String? preview;
    for (final raw in _values(data)) {
      final at = _date(raw['lastModifiedDateTime']) ??
          _date(raw['createdDateTime']);
      if (at != null && (newest == null || at.isAfter(newest))) {
        newest = at;
        preview = _previewOf(raw);
      }
    }
    return newest == null
        ? channel
        : channel.copyWith(lastActivity: newest, lastMessagePreview: preview);
  }

  @override
  Future<ChatMessagePage> messages(
    ChatConversation conversation, {
    String? cursor,
  }) async {
    final Map<String, dynamic> data;
    if (cursor != null) {
      data = await _get(cursor);
    } else if (conversation.isChannel) {
      data = await _get(
        '/teams/${conversation.teamId}/channels/${conversation.id}/messages',
        query: {r'$top': 50, r'$expand': 'replies'},
      );
    } else {
      data = await _get(
        '/chats/${conversation.id}/messages',
        query: {r'$top': 50, r'$orderby': 'createdDateTime desc'},
      );
    }
    final messages = _values(data).map(_parseMessage).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return ChatMessagePage(messages: messages, nextLink: _nextLink(data));
  }

  /// How many pages of changes one delta reads before giving up on it: past
  /// this much churn a fresh first page is cheaper and just as right.
  static const _deltaPages = 4;

  /// A chat's changes by `lastModifiedDateTime`, which a new message, an
  /// edit, a deletion and a reaction all move. Graph filters on it only
  /// ordered by it, and only as a range — hence the `lt` a day ahead.
  /// Channels have no such filter, and a NightMail Server answers any
  /// `$filter` with 400 (nightware's phase-23 known gaps): null, a full page.
  @override
  Future<ChatMessageDelta?> messagesSince(
      ChatConversation conversation, DateTime since) async {
    if (conversation.isChannel || isNightmailServer) return null;
    String stamp(DateTime t) => t.toUtc().toIso8601String();
    final until = DateTime.now().add(const Duration(days: 1));
    final raw = <Map<String, dynamic>>[];
    String? next = '/chats/${conversation.id}/messages';
    Map<String, dynamic>? query = {
      r'$top': 50,
      r'$orderby': 'lastModifiedDateTime desc',
      r'$filter': 'lastModifiedDateTime gt ${stamp(since)} and '
          'lastModifiedDateTime lt ${stamp(until)}',
    };
    for (var page = 0; next != null; page++) {
      if (page == _deltaPages) return null;
      final data = await _get(next, query: query);
      query = null;
      raw.addAll(_values(data));
      next = _nextLink(data);
    }
    DateTime? watermark;
    for (final m in raw) {
      final t = DateTime.tryParse(m['lastModifiedDateTime'] as String? ?? '');
      if (t != null && (watermark == null || t.isAfter(watermark))) {
        watermark = t;
      }
    }
    return ChatMessageDelta(
      messages: raw.map(_parseMessage).toList(),
      watermark: watermark,
      complete: true,
    );
  }

  @override
  bool canThread(ChatConversation conversation) => conversation.hasThreads;

  @override
  Future<List<ChatMessage>> replies(
    ChatConversation channel,
    ChatMessage post,
  ) async {
    final out = <ChatMessage>[];
    String? next = '/teams/${channel.teamId}/channels/${channel.id}'
        '/messages/${post.id}/replies';
    Map<String, dynamic>? query = {r'$top': 50};
    for (var page = 0; next != null && page < 10; page++) {
      final data = await _get(next, query: query);
      query = null;
      out.addAll(_values(data).map(_parseMessage));
      next = _nextLink(data);
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  @override
  Future<ChatMessage> send(
    ChatConversation conversation,
    String text, {
    ChatMessage? replyTo,
    ChatOutgoingImage? image,
  }) async {
    final path = !conversation.isChannel
        ? '/chats/${conversation.id}/messages'
        : replyTo == null
            ? '/teams/${conversation.teamId}/channels/${conversation.id}/messages'
            : '/teams/${conversation.teamId}/channels/${conversation.id}'
                '/messages/${replyTo.id}/replies';
    final data = await _post(path, image == null
        ? {'body': {'contentType': 'text', 'content': text}}
        : imageMessageBody(text, image));
    return _parseMessage(data);
  }

  /// A message carrying [image] as hosted content, the way Teams sends a
  /// pasted picture: the body refers to it by a temporary id, and Graph
  /// answers with the `…/hostedContents/{id}/$value` it was given.
  @visibleForTesting
  static Map<String, dynamic> imageMessageBody(
      String text, ChatOutgoingImage image) {
    var size = '';
    final w = image.width, h = image.height;
    if (w != null && h != null && w > 0 && h > 0) {
      // Teams draws it at the size given; a screenshot's pixels would fill
      // the conversation.
      final scale = w > _imageWidth ? _imageWidth / w : 1.0;
      final sw = (w * scale).round(), sh = (h * scale).round();
      size = ' width="$sw" height="$sh"'
          ' style="vertical-align:bottom; width:${sw}px; height:${sh}px"';
    }
    final caption = text.trim().isEmpty ? '' : '<p>${_escape(text)}</p>';
    return {
      'body': {
        'contentType': 'html',
        'content': '$caption<p><img src="../hostedContents/1/\$value"'
            ' alt="${_escape(image.name)}"$size></p>',
      },
      'hostedContents': [
        {
          '@microsoft.graph.temporaryId': '1',
          'contentBytes': base64Encode(image.bytes),
          'contentType': image.mimeType,
        },
      ],
    };
  }

  static const _imageWidth = 360;

  /// Hosted contents are Graph's; nightware's chat API has none.
  @override
  bool canSendImage(ChatConversation conversation) => !isNightmailServer;

  /// Creates (or, as both servers do for an existing pair, returns) the
  /// one-on-one chat between the signed-in user and [email].
  /// A Microsoft 365 channel would need `ChannelMessage.ReadWrite`; a
  /// NightMail Server lets anyone edit their own post.
  @override
  bool canEdit(ChatConversation conversation) =>
      !conversation.isChannel || isNightmailServer;

  @override
  Future<ChatMessage> edit(
    ChatConversation conversation,
    ChatMessage message,
    String text,
  ) async {
    // 204, no body: the edit is what was sent.
    await _patch(_messagePath(conversation, message), {
      'body': {'contentType': 'text', 'content': text},
    });
    return message.withEdit(
      bodyHtml: _escape(text),
      editableText: text,
      editedAt: DateTime.now(),
    );
  }

  /// A chat message, a channel post, or a reply under its post.
  static String _messagePath(ChatConversation conversation, ChatMessage m) {
    final channel =
        '/teams/${conversation.teamId}/channels/${conversation.id}/messages';
    return !conversation.isChannel
        ? '/chats/${conversation.id}/messages/${m.id}'
        : m.replyToId == null
            ? '$channel/${m.id}'
            : '$channel/${m.replyToId}/replies/${m.id}';
  }

  /// Chats under `Chat.ReadWrite`; channels under `ChannelMessage.Send`,
  /// which (unlike an edit) is all Microsoft asks for. A NightMail Server
  /// serves the same routes.
  @override
  bool canReact(ChatConversation conversation) => true;

  /// `setReaction` with the emoji itself — Graph takes unicode, and keeps a
  /// repeat as the one reaction it already has, so a repeat is only known
  /// by the caller (from [ChatReaction.userIds]); 204 always says added.
  @override
  Future<bool> react(
    ChatConversation conversation,
    ChatMessage message,
    String emoji,
  ) async {
    await _post('${_messagePath(conversation, message)}/setReaction',
        {'reactionType': emoji});
    return true;
  }

  /// `unsetReaction`, under the same access as `setReaction`. 204 either way:
  /// Graph does not say whether there was one to remove.
  @override
  Future<bool> unreact(
    ChatConversation conversation,
    ChatMessage message,
    String emoji,
  ) async {
    await _post('${_messagePath(conversation, message)}/unsetReaction',
        {'reactionType': emoji});
    return true;
  }

  /// A group chat's topic (`Chat.ReadWrite`). A channel only on a NightMail
  /// Server: Microsoft wants `ChannelSettings.ReadWrite.All`, admin consent.
  /// A meeting chat's topic is the meeting's.
  @override
  bool canRename(ChatConversation conversation) =>
      conversation.kind == ChatKind.group ||
      (conversation.isChannel && isNightmailServer);

  @override
  Future<ChatConversation> rename(
    ChatConversation conversation,
    String title,
  ) async {
    // Microsoft answers 204 with no body, nightware with the chat: the
    // title is what was sent either way.
    if (conversation.isChannel) {
      await _patch('/teams/${conversation.teamId}/channels/${conversation.id}',
          {'displayName': title});
    } else {
      await _patch('/chats/${conversation.id}', {'topic': title});
    }
    return conversation.copyWith(title: title);
  }

  @override
  Future<ChatConversation> createOneOnOne({
    required String ownEmail,
    required String email,
    required String displayName,
  }) async {
    // Microsoft binds members by directory id — its reference shows no
    // other form, and `users('{address}')` only resolves a UPN, which is not
    // the mail address in every tenant. Nightware resolves an address itself
    // (ADR 0009 D2). Built on the account's own Graph root: a literal
    // Microsoft URL here would send a server account's members to Microsoft
    // (no_hardcoded_graph_urls_test).
    final own = isNightmailServer
        ? ownEmail
        : await ownUserId(null) ??
            (throw const ServerException(
                message: 'Could not read your user id.'));
    final other = isNightmailServer ? email : await _userIdOf(email);
    String bind(String key) =>
        "${_root()}/users('${Uri.encodeComponent(key)}')";
    Map<String, dynamic> member(String key) => {
          '@odata.type': '#microsoft.graph.aadUserConversationMember',
          'roles': ['owner'],
          'user@odata.bind': bind(key),
        };
    final data = await _post('/chats', {
      'chatType': 'oneOnOne',
      'members': [member(own), member(other)],
    });
    final chat = _parseChat(data, null);
    return ChatConversation(
      id: chat?.id ?? (data['id'] as String),
      kind: ChatKind.oneOnOne,
      title: displayName.isNotEmpty ? displayName : email,
      lastActivity: DateTime.now(),
      members: [ChatMember(displayName: displayName, email: email)],
    );
  }

  Future<String> _ownUserId() async {
    final id = (await _get('/me', query: {r'$select': 'id'}))['id'];
    if (id is! String) {
      throw const ServerException(message: 'Could not read your user id.');
    }
    return id;
  }

  /// The directory id of whoever receives mail at [email]: the UPN first
  /// (the common case), then `mail`, then any proxy address — an alias. A
  /// 404 means nobody in the directory: an external address.
  Future<String> _userIdOf(String email) async {
    try {
      final id = (await _get('/users/${Uri.encodeComponent(email)}',
          query: {r'$select': 'id'}))['id'];
      if (id is String) return id;
    } on ServerException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
    final quoted = email.replaceAll("'", "''");
    final byMail = _values(await _get('/users', query: {
      r'$filter': "mail eq '$quoted'",
      r'$select': 'id',
    }));
    if (byMail.isNotEmpty && byMail.first['id'] is String) {
      return byMail.first['id'] as String;
    }
    // proxyAddresses is an advanced query: eventual consistency and $count.
    try {
      final r = await _dio.get<Map<String, dynamic>>('/users',
          queryParameters: {
            r'$filter': "proxyAddresses/any(p:p eq 'smtp:$quoted')",
            r'$select': 'id',
            r'$count': 'true',
          },
          options: Options(headers: {'ConsistencyLevel': 'eventual'}));
      final byProxy = _values(r.data ?? const {});
      if (byProxy.isNotEmpty && byProxy.first['id'] is String) {
        return byProxy.first['id'] as String;
      }
    } on DioException catch (e) {
      throw _map(e);
    }
    throw const ServerException(message: 'Not in the directory', statusCode: 404);
  }

  /// Microsoft Search over chat and channel messages. A NightMail Server does
  /// not serve `/search/query`; the repository searches its history itself.
  @override
  Future<Set<String>?> directoryMembers(List<String> emails) async => null;

  @override
  Future<List<ChatSearchHit>> search(String query) async {
    final data = await _post('/search/query', {
      'requests': [
        {
          'entityTypes': ['chatMessage'],
          'query': {'queryString': query},
          'from': 0,
          'size': 25,
        },
      ],
    });
    final hits = <ChatSearchHit>[];
    for (final response in _list(data['value'])) {
      for (final container in _list(response['hitsContainers'])) {
        for (final hit in _list(container['hits'])) {
          final resource = hit['resource'];
          if (resource is! Map<String, dynamic>) continue;
          final summary = hit['summary'] as String?;
          final body = resource['body'];
          final withBody = {
            ...resource,
            // Search answers carry a highlighted summary and often no body.
            if (body is! Map || (body['content'] as String? ?? '').isEmpty)
              'body': {
                'contentType': 'html',
                'content': (summary ?? '')
                    .replaceAll(RegExp(r'</?c0>'), '')
                    .replaceAll('<ddd/>', '…'),
              },
          };
          final channel = resource['channelIdentity'];
          hits.add(ChatSearchHit(
            message: _parseMessage(withBody),
            chatId: resource['chatId'] as String?,
            teamId: channel is Map ? channel['teamId'] as String? : null,
            channelId: channel is Map ? channel['channelId'] as String? : null,
          ));
        }
      }
    }
    return hits;
  }

  // ---- parsing ------------------------------------------------------------

  ChatConversation? _parseChat(Map<String, dynamic> raw, String? ownId) {
    final id = raw['id'] as String?;
    if (id == null) return null;
    final kind = switch (raw['chatType']) {
      'oneOnOne' => ChatKind.oneOnOne,
      'meeting' => ChatKind.meeting,
      _ => ChatKind.group,
    };
    final members = _list(raw['members'])
        .map((m) => ChatMember(
              displayName: (m['displayName'] as String?) ?? '',
              userId: m['userId'] as String?,
              email: (m['email'] as String?)?.trim().toLowerCase(),
            ))
        .toList();
    final others = members
        .where((m) => m.email == null || !_own.contains(m.email))
        .toList();
    final topic = (raw['topic'] as String?)?.trim();
    final title = topic != null && topic.isNotEmpty && kind != ChatKind.oneOnOne
        ? topic
        : others.isNotEmpty
            ? others
                .map((m) => m.displayName.isNotEmpty
                    ? m.displayName
                    : (m.email ?? ''))
                .where((n) => n.isNotEmpty)
                .join(', ')
            : (topic?.isNotEmpty ?? false)
                ? topic!
                : _previewSender(raw, ownId) ?? 'Chat';
    final preview = raw['lastMessagePreview'];
    final previewAt = preview is Map<String, dynamic>
        ? _date(preview['createdDateTime'])
        : null;
    return ChatConversation(
      id: id,
      kind: kind,
      title: title.isEmpty ? 'Chat' : title,
      lastActivity: previewAt ??
          _date(raw['lastUpdatedDateTime']) ??
          _date(raw['createdDateTime']),
      lastMessagePreview:
          preview is Map<String, dynamic> ? _previewOf(preview) : null,
      members: others,
      unread: ownId != null && isUnread(raw, ownId),
      // Listed with its preview expanded, and there is none. A chat as
      // created or fetched without the expansion is not known to be empty.
      noMessages: raw.containsKey('lastMessagePreview') && preview == null,
    );
  }

  /// The one-on-one listing without members (the unread poll's) is named by
  /// whoever wrote its newest message, when that is not the user — in an
  /// unread one-on-one, always the other person.
  static String? _previewSender(Map<String, dynamic> raw, String? ownId) {
    if (raw['chatType'] != 'oneOnOne') return null;
    final preview = raw['lastMessagePreview'];
    final from = preview is Map ? preview['from'] : null;
    final user = from is Map ? from['user'] : null;
    if (user is! Map || user['id'] == null || user['id'] == ownId) return null;
    final name = (user['displayName'] as String?)?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  /// Someone other than [ownId] wrote the newest message, after the user's
  /// read marker. A null marker is unread: on Microsoft the chat was never
  /// read, on Nightware the marker is not on the newest message (phase 23).
  /// A hidden chat, a system event and the user's own message never are.
  @visibleForTesting
  static bool isUnread(Map<String, dynamic> raw, String ownId) {
    final viewpoint = raw['viewpoint'];
    if (viewpoint is Map && viewpoint['isHidden'] == true) return false;
    final preview = raw['lastMessagePreview'];
    if (preview is! Map || preview['isDeleted'] == true) return false;
    if (preview['messageType'] == 'systemEventMessage') return false;
    final from = preview['from'];
    final user = from is Map ? from['user'] : null;
    final sender = user is Map ? user['id'] as String? : null;
    if (sender == null || sender == ownId) return false;
    final sent = _date(preview['createdDateTime']);
    if (sent == null) return false;
    final read = viewpoint is Map
        ? _date(viewpoint['lastMessageReadDateTime'])
        : null;
    return read == null || sent.isAfter(read);
  }

  ChatMessage _parseMessage(Map<String, dynamic> raw) {
    final from = raw['from'];
    // A search hit names its sender as an email address, not a user.
    final user = from is Map
        ? from['user'] ??
            from['application'] ??
            (from['emailAddress'] is Map
                ? {'displayName': (from['emailAddress'] as Map)['name']}
                : null)
        : null;
    final body = raw['body'];
    final contentType = body is Map ? body['contentType'] as String? : null;
    var content = body is Map ? (body['content'] as String?) ?? '' : '';
    if (contentType == 'text') content = _escape(content);
    final isSystem = raw['messageType'] == 'systemEventMessage' ||
        raw['messageType'] == 'unknownFutureValue';
    if (isSystem) content = _escape(_describeEvent(raw['eventDetail']));

    final reactionCounts = <String, int>{};
    final reactors = <String, List<String>>{};
    for (final r in _list(raw['reactions'])) {
      final type = _reactionEmoji(r['reactionType'] as String?);
      if (type == null) continue;
      reactionCounts[type] = (reactionCounts[type] ?? 0) + 1;
      final by = r['user'];
      final user = by is Map ? by['user'] : null;
      final id = user is Map ? user['id'] as String? : null;
      if (id != null) (reactors[type] ??= []).add(id);
    }

    final replies = _list(raw['replies']).map(_parseMessage).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return ChatMessage(
      id: raw['id'] as String? ?? '',
      createdAt: _date(raw['createdDateTime']) ?? DateTime.now(),
      senderName: (user is Map ? user['displayName'] as String? : null) ?? '',
      senderUserId: user is Map ? user['id'] as String? : null,
      bodyHtml: content,
      replyToId: raw['replyToId'] as String?,
      subject: (raw['subject'] as String?)?.trim().isEmpty ?? true
          ? null
          : raw['subject'] as String,
      editedAt: _date(raw['lastEditedDateTime']),
      isDeleted: raw['deletedDateTime'] != null,
      isSystem: isSystem,
      reactions: [
        for (final e in reactionCounts.entries)
          ChatReaction(
            emoji: e.key,
            count: e.value,
            userIds: reactors[e.key] ?? const [],
          ),
      ],
      replies: replies,
      replyCount: raw['replies@odata.count'] as int?,
      attachmentNames: [
        for (final a in _list(raw['attachments']))
          // A quoted reply in a chat travels as a messageReference
          // attachment; it is not a file.
          if (a['contentType'] != 'messageReference' &&
              (a['name'] as String?)?.isNotEmpty == true)
            a['name'] as String,
      ],
      editableText: isSystem ? null : editableTextOf(raw),
    );
  }

  /// A message's body as plain text that says the same, or null when it
  /// cannot: a mention, an attachment (a file, a quoted reply, a card), or
  /// HTML beyond the paragraphs, breaks, emoji and bare links Teams wraps
  /// typed text in.
  @visibleForTesting
  static String? editableTextOf(Map<String, dynamic> raw) {
    if (_list(raw['attachments']).isNotEmpty ||
        _list(raw['mentions']).isNotEmpty) {
      return null;
    }
    final body = raw['body'];
    if (body is! Map) return null;
    final content = body['content'] as String? ?? '';
    if (body['contentType'] == 'text') {
      return content.trim().isEmpty ? null : content;
    }
    const ci = false;
    var s = content
        .replaceAll(RegExp(r'\r?\n'), ' ')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: ci), '\n')
        .replaceAll(
            RegExp(r'</(p|div)>\s*<(p|div)(\s[^>]*)?>', caseSensitive: ci),
            '\n')
        .replaceAll(RegExp(r'</?(p|div)(\s[^>]*)?>', caseSensitive: ci), '')
        .replaceAllMapped(
            RegExp(r'<emoji\s[^>]*alt="([^"]*)"[^>]*>(</emoji>)?',
                caseSensitive: ci),
            (m) => m[1]!);
    var lossy = false;
    s = s.replaceAllMapped(
        RegExp(r'<a\s[^>]*href="([^"]*)"[^>]*>([^<]*)</a>', caseSensitive: ci),
        (m) {
      if (_decode(m[1]!) == _decode(m[2]!)) return m[2]!;
      lossy = true;
      return '';
    });
    if (lossy || s.contains('<')) return null;
    final text = _decode(s).trim();
    return text.isEmpty ? null : text;
  }

  static String _decode(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#160;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  static String? _reactionEmoji(String? type) => switch (type) {
        null || '' => null,
        'like' => '👍',
        'heart' => '❤️',
        'laugh' => '😆',
        'surprised' => '😮',
        'sad' => '😢',
        'angry' => '😠',
        _ => type,
      };

  static String _describeEvent(Object? detail) {
    if (detail is! Map) return 'Conversation updated';
    final type = (detail['@odata.type'] as String? ?? '').split('.').last;
    String names(Object? members) => _list(members)
        .map((m) => m['displayName'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .join(', ');
    return switch (type) {
      'membersAddedEventMessageDetail' =>
        'Added ${names(detail['members'])}'.trim(),
      'membersDeletedEventMessageDetail' =>
        'Removed ${names(detail['members'])}'.trim(),
      'chatRenamedEventMessageDetail' =>
        'Renamed to "${detail['chatDisplayName'] ?? ''}"',
      'callEndedEventMessageDetail' => 'Call ended',
      'callStartedEventMessageDetail' => 'Call started',
      'channelAddedEventMessageDetail' => 'Channel created',
      _ => 'Conversation updated',
    };
  }

  String _previewOf(Map<String, dynamic> raw) {
    final body = raw['body'];
    final text = body is Map ? (body['content'] as String?) ?? '' : '';
    final plain = (body is Map && body['contentType'] == 'text')
        ? text
        : htmlToPlainText(text);
    return plain.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('\n', '<br>');

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  static List<Map<String, dynamic>> _list(Object? v) => v is List
      ? v.whereType<Map<String, dynamic>>().toList()
      : const [];

  static List<Map<String, dynamic>> _values(Map<String, dynamic> data) =>
      _list(data['value']);

  // ---- images ---------------------------------------------------------------

  /// Teams keeps a pasted picture as the message's hosted content, linked
  /// from the body as `…/chats/{id}/messages/{id}/hostedContents/{id}/$value`
  /// on the account's own Graph root — fetched with its token. A GIF or
  /// sticker points at a public CDN and goes without it.
  @override
  Future<Uint8List?> image(String src) async {
    final uri = Uri.tryParse(src);
    if (uri == null) return null;
    final root = Uri.tryParse(_root());
    final own = root != null &&
        uri.scheme == root.scheme &&
        uri.host == root.host &&
        uri.port == root.port;
    if (own) return fetchImageBytes(_dio, src);
    if (uri.scheme != 'https') return null;
    return fetchImageBytes(publicImageClient, src);
  }

  /// Microsoft serves a 64-pixel rendition; a NightMail Server only the
  /// photo itself (`/users/{id}/photo/$value`, nightware's directory routes).
  @override
  Future<Uint8List?> photo(String userId) {
    final id = Uri.encodeComponent(userId);
    return fetchImageBytes(
      _dio,
      isNightmailServer
          ? '/users/$id/photo/\$value'
          : '/users/$id/photos/64x64/\$value',
    );
  }

  // ---- transport ----------------------------------------------------------

  String _root() {
    final base = _dio.options.baseUrl;
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  /// A server's nextLink is followed only on the account's own Graph root —
  /// it is requested with the account's bearer token.
  String? _nextLink(Map<String, dynamic> data) {
    final link = data['@odata.nextLink'] as String?;
    if (link == null) return null;
    final root = Uri.tryParse(_root());
    final next = Uri.tryParse(link);
    if (root == null || next == null) return null;
    if (next.scheme != root.scheme ||
        next.host != root.host ||
        next.port != root.port) {
      return null;
    }
    return link;
  }

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
    Map<String, dynamic> body,
  ) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(path, data: body);
      return r.data ?? const {};
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  Future<void> _patch(String path, Map<String, dynamic> body) async {
    try {
      await _dio.patch<Object?>(path, data: body);
    } on DioException catch (e) {
      throw _map(e);
    }
  }

  /// The same mapping as `GraphApiDatasourceImpl._mapDioException`.
  static Exception _map(DioException e) {
    if (e.error is AuthException) return e.error as AuthException;
    if (e.error is NetworkException) return e.error as NetworkException;
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return NetworkException(message: e.message ?? 'Network error');
    }
    final status = e.response?.statusCode;
    String? message;
    final data = e.response?.data;
    if (data is Map && data['error'] is Map) {
      message = (data['error'] as Map)['message'] as String?;
    }
    if (status == 401) {
      return AuthException(message: message ?? 'Authentication required');
    }
    return ServerException(
      message: message ??
          (status != null ? 'Server error ($status)' : 'Unknown server error'),
      statusCode: status,
    );
  }
}
