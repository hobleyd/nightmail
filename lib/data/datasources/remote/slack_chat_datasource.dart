import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/error/exceptions.dart';
import '../../../domain/entities/chat.dart';
import '../../../infrastructure/slack/slack_workspaces.dart';
import 'chat_images.dart';
import 'chat_remote_datasource.dart';

/// Slack's Web API as the signed-in user of one workspace (a user token from
/// [SlackWorkspaces.connect]).
///
/// Direct messages are one-on-ones, group DMs (`mpim`) groups, and public
/// and private channels [ChatKind.space]s with threads — Slack keeps a
/// thread's replies out of `conversations.history`, so a post carries its
/// `reply_count` and the thread panel reads `conversations.replies`.
///
/// Every call goes to `slack.com` with the workspace's token; an image is
/// fetched with it only from `files.slack.com`. A refused token flags the
/// workspace for reconnecting ([SlackReconnectException]) and never reaches
/// the email accounts' re-auth. See `docs/claude/chat.md`.
class SlackChatDatasource implements ChatRemoteDatasource {
  SlackChatDatasource({
    required this._workspaces,
    required this.teamId,
    Dio? dio,
  }) : _dio = dio ?? _sharedDio;

  final SlackWorkspaces _workspaces;
  final String teamId;
  final Dio _dio;

  static final _sharedDio = Dio(BaseOptions(
    baseUrl: SlackWorkspaces.apiBase,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
  ));

  /// People by `team|U…`, from `users.info` — a message names its sender by
  /// id alone. Kept for the session, as Google's titles are.
  static final _users = <String, _SlackUser>{};

  /// `users.lookupByEmail` answers by `team|address`; null is "not in this
  /// workspace", remembered so the pane does not ask on every email.
  static final _byEmail = <String, String?>{};

  /// The newest message's `ts` per `team|conversation`, as far as anything
  /// has read it — what the unread poll orders its checks by.
  static final _latest = <String, String>{};

  /// Direct messages by the other person's user id, per team, and when they
  /// were listed: [findOneOnOne] never opens one, so it looks here.
  static final _ims = <String, Map<String, String>>{};
  static final _imsListedAt = <String, DateTime>{};

  /// Where the unread poll's round-robin over conversations without known
  /// activity has got to, per team.
  static final _rotation = <String, int>{};

  /// How many direct and group messages one unread poll asks about:
  /// `conversations.info` is Tier 3 (50+ a minute) and the window shares it.
  static const _unreadChecked = 15;

  @visibleForTesting
  static void forgetAll() {
    _users.clear();
    _byEmail.clear();
    _latest.clear();
    _ims.clear();
    _imsListedAt.clear();
    _rotation.clear();
  }

  @override
  bool get searchesOnServer => true;

  @override
  bool get findsOneOnOneDirectly => true;

  // ---- listings -----------------------------------------------------------

  /// Every conversation the user is in. No activity: Slack's listings carry
  /// none, so it is filled in per conversation by [channelActivity] (the
  /// chat window asks once per load, four at a time).
  @override
  Future<List<ChatConversation>> listChats() async {
    final raw = await _memberships('public_channel,private_channel,mpim,im');
    final own = await _ownId();
    // The user's own handle too, to leave it out of group DMs' titles.
    await _resolveUsers([
      ?own,
      for (final c in raw)
        if (c['is_im'] == true && c['user'] is String) c['user'] as String,
    ]);
    return [for (final c in raw) ?_parseConversation(c, own)];
  }

  Future<List<Map<String, dynamic>>> _memberships(String types) async {
    final out = <Map<String, dynamic>>[];
    String? cursor;
    for (var page = 0; page < 10; page++) {
      final data = await _call('users.conversations', {
        'types': types,
        'exclude_archived': 'true',
        'limit': '200',
        'cursor': ?cursor,
      });
      out.addAll(_list(data['channels']));
      cursor = (data['response_metadata'] as Map?)?['next_cursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    final ims = _ims[teamId] = {};
    for (final c in out) {
      if (c['is_im'] == true && c['user'] is String) {
        ims[c['user'] as String] = c['id'] as String;
      }
    }
    _imsListedAt[teamId] = DateTime.now();
    return out;
  }

  /// Direct and group messages only: channels in Slack are read loosely, as
  /// Teams channels are, and carry no dot. Each poll asks about the
  /// [_unreadChecked] most recently active, the slots left over going round
  /// the ones whose activity is not yet known.
  @override
  Future<List<ChatConversation>> listRecentChats() async {
    final raw = await _memberships('mpim,im');
    final own = await _ownId();
    if (own == null || raw.isEmpty) return const [];
    String? latestOf(Map<String, dynamic> c) => _latest['$teamId|${c['id']}'];
    final known = raw.where((c) => latestOf(c) != null).toList()
      ..sort((a, b) => latestOf(b)!.compareTo(latestOf(a)!));
    final unknown = raw.where((c) => latestOf(c) == null).toList();
    final picked = known.take(_unreadChecked ~/ 2 + 3).toList();
    if (unknown.isNotEmpty) {
      final start = (_rotation[teamId] ?? 0) % unknown.length;
      final room = _unreadChecked - picked.length;
      for (var i = 0; i < room && i < unknown.length; i++) {
        picked.add(unknown[(start + i) % unknown.length]);
      }
      _rotation[teamId] = start + room;
    }
    for (final c in known.skip(picked.length)) {
      if (picked.length >= _unreadChecked) break;
      if (!picked.contains(c)) picked.add(c);
    }

    final out = <ChatConversation>[];
    for (var i = 0; i < picked.length; i += 4) {
      await Future.wait(picked.skip(i).take(4).map((c) async {
        try {
          final info = await _call(
              'conversations.info', {'channel': c['id'] as String});
          final channel = info['channel'];
          if (channel is! Map<String, dynamic>) return;
          final state = await _readState(channel, own);
          final parsed = _parseConversation({...c, ...channel}, own);
          if (parsed == null) return;
          out.add(parsed.copyWith(
            unread: state.unread,
            lastActivity: state.latest,
          ));
        } on ServerException catch (e) {
          if (e is SlackReconnectException) rethrow;
          // One that cannot be asked leaves the rest counted.
        }
      }));
    }
    return out;
  }

  /// Whether someone else has written in [channel] since the user last read
  /// it. A DM's `conversations.info` says so outright
  /// (`unread_count_display`); a group DM's names `last_read`, and the newest
  /// message after it decides.
  Future<({bool unread, DateTime? latest})> _readState(
      Map<String, dynamic> channel, String own) async {
    final id = channel['id'] as String;
    final latest = channel['latest'];
    if (latest is Map && latest['ts'] is String) {
      _latest['$teamId|$id'] = latest['ts'] as String;
    }
    final count = channel['unread_count_display'];
    if (count is num) {
      return (unread: count > 0, latest: _ts(_latest['$teamId|$id']));
    }
    final lastRead = channel['last_read'] as String?;
    final history = await _call('conversations.history', {
      'channel': id,
      'limit': '5',
      if (lastRead != null && lastRead != '0000000000.000000')
        'oldest': lastRead,
    });
    final newer = _list(history['messages']);
    final top = newer.firstOrNull?['ts'] as String?;
    if (top != null) _latest['$teamId|$id'] = top;
    final unread = lastRead != null &&
        newer.any((m) =>
            m['user'] != own &&
            m['subtype'] == null &&
            (m['ts'] as String).compareTo(lastRead) > 0);
    return (unread: unread, latest: _ts(_latest['$teamId|$id']));
  }

  /// Direct and group messages only — the scopes asked for (`im:write`,
  /// `mpim:write`) do not reach channels, and channels carry no dot.
  @override
  Future<void> markRead(ChatConversation chat) async {
    if (chat.kind != ChatKind.oneOnOne && chat.kind != ChatKind.group) return;
    final newest = _list((await _call('conversations.history',
            {'channel': chat.id, 'limit': '1'}))['messages'])
        .firstOrNull?['ts'] as String?;
    if (newest == null) return;
    await _call('conversations.mark', {'channel': chat.id, 'ts': newest},
        post: true);
  }

  @override
  Future<String?> ownUserId(ChatConversation? conversation) => _ownId();

  Future<String?> _ownId() async {
    final w = await _workspaces.byTeam(teamId);
    final id = w?.userId;
    if (id != null && id.isNotEmpty) return id;
    final data = await _call('auth.test', const {});
    return data['user_id'] as String?;
  }

  @override
  Future<List<ChatConversation>> listChannels() async => const [];

  /// [channel]'s newest message as its activity and preview — for any
  /// Slack conversation, since none lists with its activity.
  @override
  Future<ChatConversation> channelActivity(ChatConversation channel) async {
    final data = await _call(
        'conversations.history', {'channel': channel.id, 'limit': '1'});
    final newest = _list(data['messages']).firstOrNull;
    final ts = newest?['ts'] as String?;
    if (newest == null || ts == null) return channel;
    _latest['$teamId|${channel.id}'] = ts;
    await _resolveUsers(_userIdsIn([newest]));
    return channel.copyWith(
      lastActivity: _ts(ts),
      lastMessagePreview: _plain(newest['text'] as String? ?? ''),
    );
  }

  // ---- people -------------------------------------------------------------

  /// The direct message with [email], or null when they are not in the
  /// workspace or there has never been one. Never `conversations.open`, which
  /// would make one.
  @override
  Future<ChatConversation?> findOneOnOne(String email) async {
    final user = await _lookup(email);
    if (user == null) return null;
    final listedAt = _imsListedAt[teamId];
    var id = _ims[teamId]?[user];
    if (id == null &&
        (listedAt == null ||
            DateTime.now().difference(listedAt) > const Duration(minutes: 2))) {
      await _memberships('im');
      id = _ims[teamId]?[user];
    }
    if (id == null) return null;
    return ChatConversation(
      id: id,
      kind: ChatKind.oneOnOne,
      title: _users['$teamId|$user']?.name ?? email,
      members: [_member(user)],
      lastActivity: _ts(_latest['$teamId|$id']),
    );
  }

  @override
  Future<Set<String>?> directoryMembers(List<String> emails) async {
    final found = await Future.wait(emails.take(_lookups).map((e) async {
      try {
        return await _lookup(e) == null ? null : e.trim().toLowerCase();
      } on ServerException catch (err) {
        if (err is SlackReconnectException) rethrow;
        return null;
      }
    }));
    return {for (final e in found) ?e};
  }

  /// Addresses on one email [directoryMembers] asks Slack about; each new one
  /// is a `users.lookupByEmail` (Tier 3).
  static const _lookups = 12;

  Future<String?> _lookup(String email) async {
    final key = '$teamId|${email.trim().toLowerCase()}';
    if (_byEmail.containsKey(key)) return _byEmail[key];
    try {
      final data = await _call(
          'users.lookupByEmail', {'email': email.trim().toLowerCase()});
      final user = data['user'];
      if (user is! Map<String, dynamic> || user['deleted'] == true) {
        return _byEmail[key] = null;
      }
      final id = user['id'] as String;
      _users['$teamId|$id'] = _SlackUser.fromJson(user);
      return _byEmail[key] = id;
    } on SlackApiException catch (e) {
      if (e.error == 'users_not_found') return _byEmail[key] = null;
      throw ServerException(message: 'Slack: ${e.error}');
    }
  }

  // ---- messages -----------------------------------------------------------

  @override
  Future<ChatMessagePage> messages(
    ChatConversation conversation, {
    String? cursor,
  }) async {
    final data = await _call('conversations.history', {
      'channel': conversation.id,
      'limit': '50',
      'cursor': ?cursor,
    });
    final raw = _list(data['messages']);
    final top = raw.firstOrNull?['ts'] as String?;
    if (cursor == null && top != null) {
      _latest['$teamId|${conversation.id}'] = top;
    }
    await _resolveUsers(_userIdsIn(raw));
    final next = (data['response_metadata'] as Map?)?['next_cursor'] as String?;
    return ChatMessagePage(
      messages: [for (final m in raw) _parseMessage(m)],
      nextLink: data['has_more'] == true && next != null && next.isNotEmpty
          ? next
          : null,
    );
  }

  @override
  Future<List<ChatMessage>> replies(
    ChatConversation conversation,
    ChatMessage post,
  ) async {
    final raw = <Map<String, dynamic>>[];
    String? cursor;
    for (var page = 0; page < 5; page++) {
      final data = await _call('conversations.replies', {
        'channel': conversation.id,
        'ts': post.id,
        'limit': '200',
        'cursor': ?cursor,
      });
      raw.addAll(_list(data['messages']));
      cursor = (data['response_metadata'] as Map?)?['next_cursor'] as String?;
      if (data['has_more'] != true || cursor == null || cursor.isEmpty) break;
    }
    await _resolveUsers(_userIdsIn(raw));
    return [
      for (final m in raw)
        if (m['ts'] != post.id) _parseMessage(m),
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<ChatMessage> send(
    ChatConversation conversation,
    String text, {
    ChatMessage? replyTo,
  }) async {
    final data = await _call(
      'chat.postMessage',
      {
        'channel': conversation.id,
        'text': escapeText(text),
        'thread_ts': ?(replyTo == null ? null : replyTo.replyToId ?? replyTo.id),
      },
      post: true,
    );
    final message = data['message'];
    final ts = data['ts'] as String?;
    if (ts != null) _latest['$teamId|${conversation.id}'] = ts;
    return _parseMessage({
      if (message is Map<String, dynamic>) ...message,
      'ts': ?ts,
    });
  }

  /// Opens (or returns the existing) direct message with [email]. Slack shows
  /// the other person nothing until the first message lands in it.
  @override
  Future<ChatConversation> createOneOnOne({
    required String ownEmail,
    required String email,
    required String displayName,
  }) async {
    final user = await _lookup(email);
    if (user == null) {
      throw ServerException(
          message: '$email is not in this Slack workspace.', statusCode: 404);
    }
    final data = await _call('conversations.open',
        {'users': user, 'return_im': 'true'}, post: true);
    final channel = data['channel'];
    final id = channel is Map ? channel['id'] as String? : null;
    if (id == null) {
      throw const ServerException(message: 'Slack opened no conversation.');
    }
    (_ims[teamId] ??= {})[user] = id;
    return ChatConversation(
      id: id,
      kind: ChatKind.oneOnOne,
      title: _users['$teamId|$user']?.name ??
          (displayName.isNotEmpty ? displayName : email),
      members: [_member(user)],
      lastActivity: DateTime.now(),
    );
  }

  /// `search.messages` (Tier 2, user tokens only): the newest 25 matches
  /// across everything the user can read.
  @override
  Future<List<ChatSearchHit>> search(String query) async {
    final data = await _call('search.messages', {
      'query': query,
      'count': '25',
      'sort': 'timestamp',
      'sort_dir': 'desc',
    });
    final messages = data['messages'];
    final matches = messages is Map
        ? _list(messages['matches'])
        : const <Map<String, dynamic>>[];
    await _resolveUsers(_userIdsIn(matches));
    return [
      for (final m in matches)
        if ((m['channel'] as Map?)?['id'] case final String channel)
          ChatSearchHit(
            chatId: channel,
            message: _parseMessage(m),
          ),
    ];
  }

  // ---- images -------------------------------------------------------------

  /// A Slack-hosted file (`files.slack.com`) with the workspace's token;
  /// anything else only over https and with no credentials.
  @override
  Future<Uint8List?> image(String src) async {
    final uri = Uri.tryParse(src);
    if (uri == null || uri.scheme != 'https') return null;
    if (uri.host == 'files.slack.com') {
      final String token;
      try {
        token = await _workspaces.accessToken(teamId);
      } on ServerException {
        return null;
      }
      return fetchImageBytes(
        Dio(BaseOptions(
          headers: {'Authorization': 'Bearer $token'},
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
        )),
        src,
      );
    }
    return fetchImageBytes(publicImageClient, src);
  }

  /// The profile picture `users.info` named (on Slack's public avatar CDN or
  /// Gravatar — no token).
  @override
  Future<Uint8List?> photo(String userId) async {
    try {
      await _resolveUsers([userId]);
    } catch (_) {
      return null;
    }
    final url = _users['$teamId|$userId']?.image;
    if (url == null || !url.startsWith('https://')) return null;
    return fetchImageBytes(publicImageClient, url);
  }

  // ---- parsing ------------------------------------------------------------

  ChatConversation? _parseConversation(Map<String, dynamic> c, String? own) {
    final id = c['id'] as String?;
    if (id == null) return null;
    final latest = _ts(_latest['$teamId|$id']);
    if (c['is_im'] == true) {
      final user = c['user'] as String?;
      return ChatConversation(
        id: id,
        kind: ChatKind.oneOnOne,
        title: user == null
            ? 'Direct message'
            : _users['$teamId|$user']?.name ?? 'Direct message',
        members: [if (user != null) _member(user)],
        lastActivity: latest,
      );
    }
    if (c['is_mpim'] == true) {
      return ChatConversation(
        id: id,
        kind: ChatKind.group,
        title: _mpimTitle(c['name'] as String? ?? '', own),
        lastActivity: latest,
      );
    }
    return ChatConversation(
      id: id,
      kind: ChatKind.space,
      title: '#${c['name'] as String? ?? 'channel'}',
      threaded: true,
      lastActivity: latest,
    );
  }

  /// A group DM is named `mpdm-alice--bob--carol-1`: the members' handles,
  /// less the user's own when it is known.
  String _mpimTitle(String name, String? own) {
    final handles = name
        .replaceFirst(RegExp(r'^mpdm-'), '')
        .replaceFirst(RegExp(r'-\d+$'), '')
        .split('--')
        .where((h) => h.isNotEmpty)
        .toList();
    final ownHandle = own == null ? null : _users['$teamId|$own']?.handle;
    final others = handles.where((h) => h != ownHandle).toList();
    return others.isEmpty ? 'Group message' : others.join(', ');
  }

  ChatMember _member(String userId) {
    final u = _users['$teamId|$userId'];
    return ChatMember(
      displayName: u?.name ?? userId,
      userId: userId,
      email: u?.email,
    );
  }

  ChatMessage _parseMessage(Map<String, dynamic> m) {
    final ts = m['ts'] as String? ?? '';
    final subtype = m['subtype'] as String?;
    final user = m['user'] as String?;
    final threadTs = m['thread_ts'] as String?;
    final edited = m['edited'];
    final files = _list(m['files']);
    final name = user != null
        ? _users['$teamId|$user']?.name ??
            (m['username'] as String? ?? user)
        : (m['username'] as String?) ??
            ((m['bot_profile'] as Map?)?['name'] as String?) ??
            'Slack';
    return ChatMessage(
      id: ts,
      createdAt: _ts(ts) ?? DateTime.now(),
      senderName: name,
      senderUserId: user,
      bodyHtml: mrkdwnToHtml(m['text'] as String? ?? '',
              userName: (id) => _users['$teamId|$id']?.name) +
          _imagesHtml(files),
      // A reply names its thread; a thread's parent names itself.
      replyToId: threadTs != null && threadTs != ts ? threadTs : null,
      editedAt: edited is Map ? _ts(edited['ts'] as String?) : null,
      isDeleted: subtype == 'tombstone' || subtype == 'message_deleted',
      isSystem: subtype != null && _systemSubtypes.contains(subtype),
      replyCount: (m['reply_count'] as num?)?.toInt(),
      reactions: [
        for (final r in _list(m['reactions']))
          if (r['name'] is String)
            ChatReaction(
              emoji: _emoji[r['name']] ?? ':${r['name']}:',
              count: (r['count'] as num?)?.toInt() ?? 1,
            ),
      ],
      attachmentNames: [
        for (final f in files)
          if (!_isImage(f) && (f['name'] as String?)?.isNotEmpty == true)
            f['name'] as String,
      ],
    );
  }

  static const _systemSubtypes = {
    'channel_join',
    'channel_leave',
    'channel_topic',
    'channel_purpose',
    'channel_name',
    'channel_archive',
    'channel_unarchive',
    'group_join',
    'group_leave',
    'group_topic',
    'group_purpose',
    'group_name',
    'pinned_item',
    'unpinned_item',
  };

  static bool _isImage(Map<String, dynamic> f) =>
      (f['mimetype'] as String? ?? '').startsWith('image/') &&
      (f['thumb_720'] ?? f['thumb_480'] ?? f['url_private']) is String;

  /// Uploaded pictures after the text, from Slack's own thumbnails (still
  /// `files.slack.com`, so [image] fetches them with the token).
  static String _imagesHtml(List<Map<String, dynamic>> files) {
    final out = StringBuffer();
    for (final f in files.where(_isImage)) {
      final src = (f['thumb_720'] ?? f['thumb_480'] ?? f['url_private'])
          as String;
      final alt = _escape(f['name'] as String? ?? 'image');
      out.write('<br><img src="${_escape(src)}" alt="$alt">');
    }
    return out.toString();
  }

  /// The ids a page of messages names — senders and `<@U…>` mentions.
  static Iterable<String> _userIdsIn(List<Map<String, dynamic>> messages) =>
      {
        for (final m in messages) ...[
          if (m['user'] is String) m['user'] as String,
          for (final match in _mention.allMatches(m['text'] as String? ?? ''))
            match[1]!,
        ],
      };

  static final _mention = RegExp(r'<@([UW][A-Z0-9]+)(?:\|[^>]*)?>');

  /// Looks up the people not already known, four at a time, at most 40 per
  /// call — Tier 4, but a long history should not cost a burst of hundreds.
  Future<void> _resolveUsers(Iterable<String> ids) async {
    final missing = ids
        .where((id) => id.isNotEmpty && !_users.containsKey('$teamId|$id'))
        .toSet()
        .take(40)
        .toList();
    for (var i = 0; i < missing.length; i += 4) {
      await Future.wait(missing.skip(i).take(4).map((id) async {
        try {
          final data = await _call('users.info', {'user': id});
          final user = data['user'];
          if (user is Map<String, dynamic>) {
            _users['$teamId|$id'] = _SlackUser.fromJson(user);
          }
        } on ServerException catch (e) {
          if (e is SlackReconnectException) rethrow;
          // Unknown people keep their id as a name.
        }
      }));
    }
  }

  static DateTime? _ts(String? ts) {
    if (ts == null) return null;
    final seconds = double.tryParse(ts);
    if (seconds == null) return null;
    return DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round());
  }

  static List<Map<String, dynamic>> _list(Object? v) => v is List
      ? v.whereType<Map<String, dynamic>>().toList()
      : const [];

  String _plain(String text) => text
      .replaceAllMapped(_mention,
          (m) => '@${_users['$teamId|${m[1]}']?.name ?? m[1]}')
      .replaceAllMapped(RegExp(r'<([^>|]+)\|([^>]+)>'), (m) => m[2]!)
      .replaceAllMapped(RegExp(r'<([^>]+)>'), (m) => m[1]!)
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  // ---- text ---------------------------------------------------------------

  /// What the user typed, escaped the way Slack wants message text: only
  /// `&`, `<` and `>` (anything between `<` and `>` would otherwise be read
  /// as a link or mention). `*bold*` and the like pass through as mrkdwn.
  static String escapeText(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// Slack mrkdwn as the HTML `ChatMessageBody` renders.
  ///
  /// Slack sends `&`, `<` and `>` already escaped, so the only raw `<…>` in
  /// [text] are its control sequences: `<@U…>` mentions (named through
  /// [userName]), `<#C…|name>` channels, `<!here>` and friends, and
  /// `<url|label>` links. The rest is `*bold*`, `_italic_`, `~strike~`,
  /// `` `code` ``, ```` ```blocks``` ```` and `&gt; ` quotes.
  static String mrkdwnToHtml(
    String text, {
    String? Function(String userId)? userName,
  }) {
    final out = StringBuffer();
    var last = 0;
    for (final m in RegExp(r'<([^<>]+)>').allMatches(text)) {
      out.write(_format(text.substring(last, m.start)));
      out.write(_control(m[1]!, userName));
      last = m.end;
    }
    out.write(_format(text.substring(last)));
    return out.toString();
  }

  static String _control(
      String inner, String? Function(String userId)? userName) {
    final bar = inner.indexOf('|');
    final target = bar < 0 ? inner : inner.substring(0, bar);
    final label = bar < 0 ? null : inner.substring(bar + 1);
    if (target.startsWith('@')) {
      final id = target.substring(1);
      return '<b>@${_escapeText(userName?.call(id) ?? label ?? id)}</b>';
    }
    if (target.startsWith('#')) {
      return '<b>#${_escapeText(label ?? 'channel')}</b>';
    }
    if (target.startsWith('!')) {
      final word = target.substring(1).split('^').first;
      return '<b>${_escapeText(label ?? '@$word')}</b>';
    }
    final href = target.replaceAll('&amp;', '&');
    if (!href.startsWith('http://') &&
        !href.startsWith('https://') &&
        !href.startsWith('mailto:')) {
      return _escapeText(label ?? target);
    }
    final shown = label ?? (href.startsWith('mailto:') ? href.substring(7) : href);
    return '<a href="${_escape(href)}">${_escapeText(shown)}</a>';
  }

  /// Text Slack already escaped (`&amp;`, `&lt;`, `&gt;`) — left as is, with
  /// a stray quote made safe for an attribute-free context.
  static String _escapeText(String s) => s.replaceAll('"', '&quot;');

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _format(String text) {
    if (text.isEmpty) return text;
    var html = text;
    html = html.replaceAllMapped(
        RegExp(r'```\n?([\s\S]*?)```'), (m) => '<pre>${m[1]}</pre>');
    html = html.replaceAllMapped(
        RegExp(r'`([^`\n]+)`'), (m) => '<code>${m[1]}</code>');
    html = html.replaceAllMapped(RegExp(r'(?<![\w*])\*([^*\n]+)\*(?![\w*])'),
        (m) => '<b>${m[1]}</b>');
    html = html.replaceAllMapped(
        RegExp(r'(?<![\w_])_([^_\n]+)_(?![\w_])'), (m) => '<i>${m[1]}</i>');
    html = html.replaceAllMapped(
        RegExp(r'(?<![\w~])~([^~\n]+)~(?![\w~])'), (m) => '<s>${m[1]}</s>');
    html = html.replaceAllMapped(RegExp(r'(^|\n)&gt; ?([^\n]*)'),
        (m) => '${m[1]}<blockquote>${m[2]}</blockquote>');
    html = html.replaceAllMapped(
        RegExp(r':([a-z0-9_+\-]+):'), (m) => _emoji[m[1]] ?? m[0]!);
    // The renderer collapses whitespace, a code block's included.
    return html.replaceAll('\n', '<br>');
  }

  /// The shortcodes Slack users type most, as the characters they stand for;
  /// anything else stays `:name:`.
  static const _emoji = {
    '+1': '👍',
    'thumbsup': '👍',
    '-1': '👎',
    'thumbsdown': '👎',
    'smile': '😄',
    'slightly_smiling_face': '🙂',
    'grinning': '😀',
    'joy': '😂',
    'laughing': '😆',
    'wink': '😉',
    'heart': '❤️',
    'tada': '🎉',
    'pray': '🙏',
    'clap': '👏',
    'fire': '🔥',
    'eyes': '👀',
    'white_check_mark': '✅',
    'heavy_check_mark': '✔️',
    'x': '❌',
    'warning': '⚠️',
    'rocket': '🚀',
    'thinking_face': '🤔',
    'ok_hand': '👌',
    'raised_hands': '🙌',
    'wave': '👋',
    '100': '💯',
    'sweat_smile': '😅',
    'cry': '😢',
  };

  // ---- transport ----------------------------------------------------------

  /// Slack answers HTTP 200 with `ok: false` for most failures. A refused
  /// token flags the workspace; a 429 waits out a short `Retry-After` once.
  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, String> params, {
    bool post = false,
  }) async {
    final token = await _workspaces.accessToken(teamId);
    for (var attempt = 0;; attempt++) {
      try {
        final options = Options(
          headers: {'Authorization': 'Bearer $token'},
          contentType: post ? Headers.formUrlEncodedContentType : null,
        );
        final r = post
            ? await _dio.post<Map<String, dynamic>>('/$method',
                data: params, options: options)
            : await _dio.get<Map<String, dynamic>>('/$method',
                queryParameters: params, options: options);
        final data = r.data ?? const {};
        if (data['ok'] == true) return data;
        final error = data['error'] as String? ?? 'unknown_error';
        if (_reconnectErrors.contains(error)) {
          await _workspaces.flagReconnect(teamId);
          final w = await _workspaces.byTeam(teamId);
          throw SlackReconnectException(w?.teamName ?? 'Slack');
        }
        if (method == 'users.lookupByEmail') throw SlackApiException(error);
        throw ServerException(
          message: _readable(error),
          statusCode: error == 'channel_not_found' ? 404 : null,
        );
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 429) {
          final wait = int.tryParse(
                  e.response?.headers.value('retry-after') ?? '') ??
              30;
          if (attempt == 0 && wait <= 20) {
            await Future<void>.delayed(Duration(seconds: wait));
            continue;
          }
          throw const ServerException(
              message: 'Slack is limiting requests; try again in a minute.',
              statusCode: 429);
        }
        if (e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout) {
          throw NetworkException(message: e.message ?? 'Network error');
        }
        throw ServerException(
          message: status != null
              ? 'Slack error ($status)'
              : e.message ?? 'Slack error',
          statusCode: status,
        );
      }
    }
  }

  /// Answers that mean the token itself is no good — or lacks a scope this
  /// version asks for, which connecting again grants.
  static const _reconnectErrors = {
    'invalid_auth',
    'not_authed',
    'token_revoked',
    'token_expired',
    'account_inactive',
    'missing_scope',
  };

  static String _readable(String error) => switch (error) {
        'not_in_channel' => 'You are not a member of that Slack channel.',
        'channel_not_found' => 'That Slack conversation no longer exists.',
        'is_archived' => 'That Slack channel is archived.',
        'restricted_action' =>
          'Your Slack workspace does not allow that.',
        'msg_too_long' => 'That message is too long for Slack.',
        _ => 'Slack: $error',
      };
}

class _SlackUser {
  const _SlackUser({
    required this.name,
    required this.handle,
    this.email,
    this.image,
  });

  /// Display name, else real name, else handle — as Slack's own client.
  final String name;
  final String handle;
  final String? email;
  final String? image;

  factory _SlackUser.fromJson(Map<String, dynamic> u) {
    final profile = u['profile'] is Map ? u['profile'] as Map : const {};
    String? nonEmpty(Object? v) =>
        v is String && v.trim().isNotEmpty ? v.trim() : null;
    final handle = nonEmpty(u['name']) ?? (u['id'] as String? ?? '');
    return _SlackUser(
      name: nonEmpty(profile['display_name']) ??
          nonEmpty(profile['real_name']) ??
          nonEmpty(u['real_name']) ??
          handle,
      handle: handle,
      email: nonEmpty(profile['email'])?.toLowerCase(),
      image: nonEmpty(profile['image_72']) ?? nonEmpty(profile['image_48']),
    );
  }
}
