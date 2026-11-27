import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../../core/error/exceptions.dart';
import '../../../core/text/emoji.dart';
import '../../../domain/entities/chat.dart';
import '../../../domain/entities/chat_mentions.dart';
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

  /// The newest thread reply's `ts` per `team|conversation`, from the
  /// `latest_reply` of the posts the unread poll reads. Kept apart from
  /// [_latest], which several reads overwrite with the newest *post*: a
  /// reply is activity too, and [markRead] marks past it.
  static final _replyLatest = <String, String>{};

  /// Conversations the last check of each found unread, per `team|id`. A
  /// poll only asks about some of them, so one not asked about this time
  /// keeps the answer it had — or an unread channel would blink out of the
  /// count whenever the rotation passed it by.
  static final _wasUnread = <String, ChatConversation>{};

  /// Direct messages by the other person's user id, per team, and when they
  /// were listed: [findOneOnOne] never opens one, so it looks here.
  static final _ims = <String, Map<String, String>>{};
  static final _imsListedAt = <String, DateTime>{};

  /// Where the unread poll's round-robin has got to, per `team|dm` and
  /// `team|channel`.
  static final _rotation = <String, int>{};

  /// How many direct and group messages, and how many channels, one unread
  /// poll asks about: `conversations.info` is Tier 3 (50+ a minute), and
  /// the main window and the chat window each poll once a minute.
  static const _unreadChecked = 15;
  static const _channelsChecked = 8;

  /// How many of a conversation's newest posts the unread poll reads — one
  /// request whatever the count. Their `latest_reply` is how a reply in a
  /// thread is seen at all (`conversations.history` leaves replies out),
  /// so a reply to an older post than these goes unseen.
  static const _postsChecked = 15;

  /// At most this many `conversations.replies` per conversation per poll,
  /// for threads whose newest reply is past the channel's `last_read`.
  /// Rate limits are per method, so these do not spend `conversations.info`'s.
  static const _threadsChecked = 2;

  /// Message subtypes that make a conversation unread, as Slack's sidebar
  /// counts them: people's and bots' messages, not joins, leaves or topic
  /// changes.
  static const _unreadSubtypes = {
    null,
    'bot_message',
    'file_share',
    'me_message',
    'thread_broadcast',
  };

  /// A workspace's own emoji by name, per team, from `emoji.list`: a picture
  /// URL, or — for an alias of a standard one — its characters. Read at most
  /// once per [_customEmojiFresh]; empty without `emoji:read`.
  static final _customEmoji = <String, Map<String, SlackCustomEmoji>>{};
  static final _customEmojiAt = <String, DateTime>{};

  /// When `users.list` last named a workspace's people, per team — at most
  /// once an hour (Tier 2), and only for a roster too big for `users.info`.
  static final _usersListedAt = <String, DateTime>{};
  static const _customEmojiFresh = Duration(hours: 1);

  @visibleForTesting
  static void forgetAll() {
    _customEmoji.clear();
    _customEmojiAt.clear();
    _users.clear();
    _byEmail.clear();
    _latest.clear();
    _replyLatest.clear();
    _wasUnread.clear();
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

  /// Direct and group messages, and channels — which Slack's sidebar bolds
  /// too, and its dock icon dots. Each poll asks about the ones last found
  /// unread, then the most recently active, of each ([_unreadChecked],
  /// [_channelsChecked]); the other half of the slots go round the rest in
  /// turn, so a channel that wakes after a quiet spell is reached within a
  /// few polls, not never. One not asked about keeps its last answer
  /// ([_wasUnread]).
  @override
  Future<List<ChatConversation>> listRecentChats() async {
    final raw =
        await _memberships('public_channel,private_channel,mpim,im');
    final own = await _ownId();
    if (own == null || raw.isEmpty) return const [];
    bool isDm(Map<String, dynamic> c) =>
        c['is_im'] == true || c['is_mpim'] == true;
    final picked = [
      ..._pick(raw.where(isDm).toList(), _unreadChecked, 'dm'),
      ..._pick(raw.where((c) => !isDm(c)).toList(), _channelsChecked,
          'channel'),
    ];

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
          final checked = parsed.copyWith(
            unread: state.unread,
            lastActivity: state.latest,
          );
          final key = '$teamId|${checked.id}';
          if (checked.unread) {
            _wasUnread[key] = checked;
          } else {
            _wasUnread.remove(key);
          }
          out.add(checked);
        } on ServerException catch (e) {
          if (e is SlackReconnectException) rethrow;
          // One that cannot be asked leaves the rest counted.
        }
      }));
    }
    // Still a member (a channel left drops out), not asked this time.
    final asked = {for (final c in out) c.id};
    for (final c in raw) {
      final id = c['id'];
      if (asked.contains(id)) continue;
      if (_wasUnread['$teamId|$id'] case final last?) out.add(last);
    }
    return out;
  }

  /// [n] of [all]: half those last found unread (so one read elsewhere
  /// clears soon) and then the most recently active, the rest in turn — in
  /// Slack's listing order, which holds still between polls where activity
  /// does not, so every one is reached within `all / (n / 2)` polls.
  List<Map<String, dynamic>> _pick(
      List<Map<String, dynamic>> all, int n, String kind) {
    if (all.length <= n) return all;
    String? latestOf(Map<String, dynamic> c) => _latest['$teamId|${c['id']}'];
    bool wasUnread(Map<String, dynamic> c) =>
        _wasUnread.containsKey('$teamId|${c['id']}');
    final known = all.where((c) => latestOf(c) != null).toList()
      ..sort((a, b) => latestOf(b)!.compareTo(latestOf(a)!));
    final picked = [
      ...all.where(wasUnread),
      ...known.where((c) => !wasUnread(c)),
    ].take(n ~/ 2).toList();
    final rest = all.where((c) => !picked.contains(c)).toList();
    final key = '$teamId|$kind';
    final start = (_rotation[key] ?? 0) % rest.length;
    final room = n - picked.length;
    for (var i = 0; i < room; i++) {
      picked.add(rest[(start + i) % rest.length]);
    }
    _rotation[key] = start + room;
    return picked;
  }

  /// Whether someone else has written in [channel] since the user last read
  /// it. A DM's `conversations.info` gives `unread_count_display`, which
  /// settles a read one; otherwise `last_read` and the newest messages
  /// decide — read whether or not any came after it, so a quiet channel's
  /// activity is learned too. Only [_unreadSubtypes] count.
  Future<({bool unread, DateTime? latest})> _readState(
      Map<String, dynamic> channel, String own) async {
    final id = channel['id'] as String;
    final latest = channel['latest'];
    if (latest is Map && latest['ts'] is String) {
      _latest['$teamId|$id'] = latest['ts'] as String;
    }
    final count = channel['unread_count_display'];
    final lastRead = channel['last_read'] as String?;
    // A DM Slack calls read is read, with no history call. One it calls
    // unread is checked like a channel: an AI app's DM (Rovo) holds only an
    // `assistant_app_thread` parent, read in Slack's side panel, which
    // need not move the DM's own marker — its count can stay above 0.
    if (count is num && (count <= 0 || lastRead == null)) {
      return (unread: count > 0, latest: _activity('$teamId|$id'));
    }
    final history = await _call('conversations.history',
        {'channel': id, 'limit': '$_postsChecked'});
    final newer = _list(history['messages']);
    final top = newer.firstOrNull?['ts'] as String?;
    if (top != null) _latest['$teamId|$id'] = top;
    bool counts(Map<String, dynamic> m, String after) =>
        m['user'] != own &&
        _unreadSubtypes.contains(m['subtype']) &&
        m['ts'] is String &&
        (m['ts'] as String).compareTo(after) > 0;
    var unread = lastRead != null && newer.any((m) => counts(m, lastRead));

    // Replies: `conversations.history` leaves them out, so a parent's
    // `latest_reply` is the only sign of one.
    String? newestReply;
    final threads = <Map<String, dynamic>>[];
    for (final m in newer) {
      final r = m['latest_reply'];
      if (r is! String) continue;
      if (newestReply == null || r.compareTo(newestReply) > 0) newestReply = r;
      if (lastRead != null && r.compareTo(lastRead) > 0) threads.add(m);
    }
    final key = '$teamId|$id';
    if (newestReply != null) {
      _replyLatest[key] = newestReply;
    } else {
      _replyLatest.remove(key);
    }
    if (!unread && lastRead != null) {
      threads.sort((a, b) =>
          (b['latest_reply'] as String).compareTo(a['latest_reply'] as String));
      for (final parent in threads.take(_threadsChecked)) {
        if (await _threadUnread(id, parent, lastRead, own, counts)) {
          unread = true;
          break;
        }
      }
    }
    return (unread: unread, latest: _activity(key));
  }

  /// Whether [parent]'s thread has a reply from someone else past both
  /// the channel's [lastRead] and the thread's own `last_read` — which
  /// Slack keeps apart (a thread read in Slack's side panel moves only its
  /// own) and gives a thread the user follows. A thread the user has never
  /// followed has none, so the channel's marker decides: opening the
  /// channel here clears it ([markRead] marks past its newest reply).
  Future<bool> _threadUnread(
    String channel,
    Map<String, dynamic> parent,
    String lastRead,
    String own,
    bool Function(Map<String, dynamic>, String) counts,
  ) async {
    final ts = parent['ts'] as String?;
    if (ts == null) return false;
    // Someone's only reply being the user's own is no news.
    final users = parent['reply_users'];
    if (users is List && users.isNotEmpty && users.every((u) => u == own)) {
      return false;
    }
    final data = await _call('conversations.replies',
        {'channel': channel, 'ts': ts, 'oldest': lastRead, 'limit': '50'});
    final replies = _list(data['messages']);
    final head = replies.where((m) => m['ts'] == ts).firstOrNull;
    final threadRead =
        (parent['last_read'] ?? head?['last_read']) as String?;
    final after = threadRead != null && threadRead.compareTo(lastRead) > 0
        ? threadRead
        : lastRead;
    final unread = replies.any((m) => m['ts'] != ts && counts(m, after));
    if (unread) {
      debugPrint('[Slack] $teamId: $channel unread by a reply in thread $ts '
          '(${threadRead == null ? 'channel' : 'thread'} last_read)');
    }
    return unread;
  }

  /// The newest post or thread reply seen in a conversation.
  DateTime? _activity(String key) {
    final post = _latest[key], reply = _replyLatest[key];
    if (reply == null || (post != null && post.compareTo(reply) >= 0)) {
      return _ts(post);
    }
    return _ts(reply);
  }

  /// A channel only with `channels:write` and `groups:write`, which
  /// workspaces connected before channels were bolded lack until they are
  /// connected again: without them the repository still counts it read
  /// here until something newer arrives, it just stays unread in Slack.
  @override
  Future<void> markRead(ChatConversation chat) async {
    _wasUnread.remove('$teamId|${chat.id}');
    if (chat.kind == ChatKind.space) {
      final scopes = (await _workspaces.byTeam(teamId))?.scopes;
      if (scopes == null ||
          !scopes.contains('channels:write') ||
          !scopes.contains('groups:write')) {
        debugPrint('[Slack] $teamId: not marking a channel read in Slack — '
            'connect the workspace again to grant channels:write');
        return;
      }
    }
    final newest = _list((await _call('conversations.history',
            {'channel': chat.id, 'limit': '1'}))['messages'])
        .firstOrNull?['ts'] as String?;
    if (newest == null) return;
    // Past the newest thread reply too, or a reply that lit the channel
    // ([_threadUnread]) would light it again on the next poll.
    final reply = _replyLatest['$teamId|${chat.id}'];
    final mark =
        reply != null && reply.compareTo(newest) > 0 ? reply : newest;
    try {
      await _call('conversations.mark', {'channel': chat.id, 'ts': mark},
          post: true);
    } on ServerException catch (e) {
      if (mark == newest || e is SlackReconnectException) rethrow;
      debugPrint('[Slack] $teamId: marking at a reply failed ($e) — '
          'marking at the newest post');
      await _call('conversations.mark', {'channel': chat.id, 'ts': newest},
          post: true);
    }
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
    if (newest == null) return channel.copyWith(noMessages: true);
    final ts = newest['ts'] as String?;
    if (ts == null) return channel;
    _latest['$teamId|${channel.id}'] = ts;
    await _resolveUsers(_userIdsIn([newest]));
    return channel.copyWith(
      lastActivity: _ts(ts),
      lastMessagePreview: _plain(_previewText(newest)),
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
    await _loadCustomEmoji();
    final next = (data['response_metadata'] as Map?)?['next_cursor'] as String?;
    return ChatMessagePage(
      messages: [for (final m in raw) _parseMessage(m)],
      nextLink: data['has_more'] == true && next != null && next.isNotEmpty
          ? next
          : null,
    );
  }

  /// Messages posted since [since] (`oldest=`). Edits, deletions, reactions
  /// and a thread's growing reply count do not show, so the repository still
  /// reads a full page now and then. Slack's limit counts calls, not their
  /// size, so this saves bytes and parsing rather than quota.
  @override
  Future<ChatMessageDelta?> messagesSince(
      ChatConversation conversation, DateTime since) async {
    final data = await _call('conversations.history', {
      'channel': conversation.id,
      'limit': '50',
      'oldest': (since.microsecondsSinceEpoch / 1e6).toStringAsFixed(6),
    });
    // More than a page since: a fresh first page instead.
    if (data['has_more'] == true) return null;
    final raw = _list(data['messages']);
    final top = raw.firstOrNull?['ts'] as String?;
    if (top != null) _latest['$teamId|${conversation.id}'] = top;
    await _resolveUsers(_userIdsIn(raw));
    await _loadCustomEmoji();
    return ChatMessageDelta(
      messages: [for (final m in raw) _parseMessage(m)],
      watermark: _ts(top),
    );
  }

  /// A DM and a group DM thread as channels do: `conversations.history`
  /// leaves the replies out, `reply_count` counts them, `conversations.replies`
  /// reads them and `thread_ts` answers in them.
  @override
  bool canThread(ChatConversation conversation) => true;

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
    await _loadCustomEmoji();
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
    ChatOutgoingFile? file,
    List<ChatMember> mentions = const [],
  }) async {
    final sent = outgoingText(text, mentions);
    if (file != null) return _sendFile(conversation, sent, replyTo, file);
    final data = await _call(
      'chat.postMessage',
      {
        'channel': conversation.id,
        'text': sent,
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

  /// `files:write`, checked when sending: a workspace connected before
  /// pictures could be sent is told to connect again.
  @override
  bool canSendImage(ChatConversation conversation) => true;

  /// The same external upload takes any file.
  @override
  bool canSendAnyFile(ChatConversation conversation) => true;

  /// Slack's external upload: ask for an upload URL, send the bytes there,
  /// then complete it into the conversation with [text] as its comment.
  /// Slack posts the message itself, after the call returns, and names no
  /// `ts` for it, so it is looked for in the newest messages — a few tries,
  /// while Slack processes the file.
  /// [text] is already [outgoingText].
  Future<ChatMessage> _sendFile(
    ChatConversation conversation,
    String text,
    ChatMessage? replyTo,
    ChatOutgoingFile file,
  ) async {
    const reconnect = ServerException(
        message: 'Connect this Slack workspace again in Settings to send '
            'pictures and files.');
    final scopes = (await _workspaces.byTeam(teamId))?.scopes;
    if (scopes == null || !scopes.contains('files:write')) throw reconnect;
    try {
      return await _upload(conversation, text, replyTo, file);
    } on SlackApiException {
      // `missing_scope`, the only answer `_call` hands back for these two:
      // granted as far as NightMail knew, refused by Slack.
      throw reconnect;
    }
  }

  Future<ChatMessage> _upload(
    ChatConversation conversation,
    String text,
    ChatMessage? replyTo,
    ChatOutgoingFile outgoing,
  ) async {
    final thread = replyTo == null ? null : replyTo.replyToId ?? replyTo.id;
    final ticket = await _call(
      'files.getUploadURLExternal',
      {'filename': outgoing.name, 'length': '${outgoing.bytes.length}'},
      post: true,
    );
    final uploadUrl = ticket['upload_url'] as String?;
    final fileId = ticket['file_id'] as String?;
    if (uploadUrl == null || fileId == null) {
      throw const ServerException(message: 'Slack did not accept the file.');
    }
    try {
      // Slack's own upload host; the URL is the credential, not the token.
      await _dio.post<void>(
        uploadUrl,
        data: outgoing.bytes,
        options: Options(headers: {
          Headers.contentTypeHeader: outgoing.mimeType,
          Headers.contentLengthHeader: outgoing.bytes.length,
        }),
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == null) {
        throw NetworkException(message: e.message ?? 'Network error');
      }
      throw ServerException(
          message: 'Slack error ($status)', statusCode: status);
    }
    final done = await _call(
      'files.completeUploadExternal',
      {
        'files': jsonEncode([
          {'id': fileId, 'title': outgoing.name},
        ]),
        'channel_id': conversation.id,
        if (text.isNotEmpty) 'initial_comment': text,
        'thread_ts': ?thread,
      },
      post: true,
    );
    // Named, so a stand-in for a file that is not a picture shows its name.
    final file = {
      'id': fileId,
      'name': outgoing.name,
      ...?_list(done['files']).firstOrNull,
    };
    for (final wait in uploadWaits) {
      await Future<void>.delayed(wait);
      final found = await _uploaded(conversation, thread, fileId);
      if (found != null) return found;
    }
    // Not posted yet: shown as sent from what is known. The conversation's
    // next full page read has the real one (its `ts`) and drops this.
    debugPrint('[Slack] uploaded $fileId; its message has not appeared yet');
    return _parseMessage({
      'ts': (DateTime.now().microsecondsSinceEpoch / 1e6).toStringAsFixed(6),
      'user': ?await _ownId(),
      'text': text,
      'files': [file],
      'thread_ts': ?thread,
    });
  }

  /// How long to wait before each look for an upload's message.
  @visibleForTesting
  static List<Duration> uploadWaits = const [
    Duration(milliseconds: 400),
    Duration(milliseconds: 800),
    Duration(milliseconds: 1500),
    Duration(milliseconds: 2500),
  ];

  /// The newest message in [conversation] (or in [thread]) sharing [fileId].
  Future<ChatMessage?> _uploaded(
    ChatConversation conversation,
    String? thread,
    String fileId,
  ) async {
    final data = thread == null
        ? await _call('conversations.history',
            {'channel': conversation.id, 'limit': '5'})
        : await _call('conversations.replies', {
            'channel': conversation.id,
            'ts': thread,
            'limit': '200',
          });
    final raw = _list(data['messages']);
    final m = (thread == null ? raw : raw.reversed).where((m) =>
        _list(m['files']).any((f) => f['id'] == fileId)).firstOrNull;
    if (m == null) return null;
    final ts = m['ts'] as String?;
    if (thread == null && ts != null) _latest['$teamId|${conversation.id}'] = ts;
    await _resolveUsers(_userIdsIn([m]));
    return _parseMessage(m);
  }

  /// Opens (or returns the existing) direct message with [email]. Slack shows
  /// the other person nothing until the first message lands in it.
  /// `chat:write` covers `chat.update` of the user's own messages.
  @override
  bool canEdit(ChatConversation conversation) => true;

  @override
  Future<ChatMessage> edit(
    ChatConversation conversation,
    ChatMessage message,
    String text,
  ) async {
    final sent = escapeText(text);
    final data = await _call(
      'chat.update',
      {'channel': conversation.id, 'ts': message.id, 'text': sent},
      post: true,
    );
    final echoed = data['message'];
    final edited = echoed is Map && echoed['edited'] is Map
        ? _ts((echoed['edited'] as Map)['ts'] as String?)
        : null;
    return message.withEdit(
      bodyHtml: mrkdwnToHtml(data['text'] as String? ?? sent,
          userName: (id) => _users['$teamId|$id']?.name,
          customEmoji: (name) => _customEmoji[teamId]?[name]),
      editableText: text,
      editedAt: edited ?? DateTime.now(),
    );
  }

  /// `reactions.add` (`reactions:write`), anywhere the user can read.
  @override
  bool canReact(ChatConversation conversation) => true;

  /// Slack takes a name, not the character: a standard emoji's from the
  /// table, a workspace's own from its `:name:`. A workspace connected before
  /// reactions were offered lacks `reactions:write` until it is connected
  /// again, which is said here rather than flagging the workspace. `already_reacted` is the
  /// user's reaction already being there.
  @override
  Future<bool> react(
    ChatConversation conversation,
    ChatMessage message,
    String emoji,
  ) async {
    final name = slackReactionName(emoji);
    if (name == null) {
      throw ServerException(message: 'Slack has no emoji for $emoji.');
    }
    final scopes = (await _workspaces.byTeam(teamId))?.scopes;
    if (scopes == null || !scopes.contains('reactions:write')) {
      throw const ServerException(
          message: 'Connect this Slack workspace again in Settings to add '
              'reactions.');
    }
    try {
      await _call(
        'reactions.add',
        {'channel': conversation.id, 'timestamp': message.id, 'name': name},
        post: true,
      );
      return true;
    } on SlackApiException catch (e) {
      if (e.error == 'already_reacted') return false;
      throw ServerException(message: _readable(e.error));
    }
  }

  /// `reactions.remove`, by the same name and under the same scope as
  /// [react]. `no_reaction` is the user's not being there (any more).
  @override
  Future<bool> unreact(
    ChatConversation conversation,
    ChatMessage message,
    String emoji,
  ) async {
    final name = slackReactionName(emoji);
    if (name == null) {
      throw ServerException(message: 'Slack has no emoji for $emoji.');
    }
    final scopes = (await _workspaces.byTeam(teamId))?.scopes;
    if (scopes == null || !scopes.contains('reactions:write')) {
      throw const ServerException(
          message: 'Connect this Slack workspace again in Settings to remove '
              'reactions.');
    }
    try {
      await _call(
        'reactions.remove',
        {'channel': conversation.id, 'timestamp': message.id, 'name': name},
        post: true,
      );
      return true;
    } on SlackApiException catch (e) {
      if (e.error == 'no_reaction') return false;
      throw ServerException(message: _readable(e.error));
    }
  }

  /// The name `reactions.add` wants for [emoji]: a custom emoji's `:name:`
  /// without its colons, else the standard emoji's (skin tone included).
  @visibleForTesting
  static String? slackReactionName(String emoji) {
    final custom = RegExp(r'^:([^:\s]+):$').firstMatch(emoji);
    if (custom != null) return custom[1];
    return emojiShortcode(emoji);
  }

  /// Public and private channels; Slack names no DM or group DM.
  @override
  bool canRename(ChatConversation conversation) =>
      conversation.kind == ChatKind.space;

  /// `conversations.rename`, under `channels:write`/`groups:write` — which a
  /// workspace connected before 1.58.1 lacks until it is connected again,
  /// so that is checked first rather than flagging the workspace.
  @override
  Future<ChatConversation> rename(
    ChatConversation conversation,
    String title,
  ) async {
    const reconnect = ServerException(
        message: 'Connect this Slack workspace again in Settings to rename '
            'channels.');
    final scopes = (await _workspaces.byTeam(teamId))?.scopes;
    if (scopes == null ||
        !scopes.contains('channels:write') ||
        !scopes.contains('groups:write')) {
      throw reconnect;
    }
    final Map<String, dynamic> data;
    try {
      data = await _call(
        'conversations.rename',
        {'channel': conversation.id, 'name': slackChannelName(title)},
        post: true,
      );
    } on SlackApiException {
      throw reconnect;
    } on ServerException catch (e) {
      // Many workspaces let only a channel's managers rename it.
      if (e.message != _readable('not_authorized')) rethrow;
      throw const ServerException(
          message: 'Only the channel\'s managers can rename it in this '
              'workspace.');
    }
    final name = (data['channel'] as Map?)?['name'] as String?;
    return conversation.copyWith(
        title: '#${name ?? slackChannelName(title)}');
  }

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
    await _loadCustomEmoji();
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

  // ---- calls --------------------------------------------------------------

  /// A huddle: Slack has no separate voice and video call.
  @override
  ChatCalling get calling => ChatCalling.huddle;

  /// A huddle link for the direct message with [person],
  /// `app.slack.com/huddle/{team}/{channel}`: opening it starts (or joins)
  /// that DM's huddle in the Slack app, which rings them. Slack documents no
  /// huddle URL — this shape is taken from what "Copy huddle link" is
  /// reported to give, and was not confirmed against a live workspace. On
  /// the desktop `launchMeetingJoinUrl` opens it as `slack://join-huddle`
  /// (`slackAppHuddleUrl`), so only the Slack app opens, with this link as
  /// the fallback. [video] is the same huddle — the camera is turned on
  /// inside it.
  ///
  /// The DM is the open conversation when that is the one-on-one with them,
  /// else one already listed; failing both, `conversations.open` makes it.
  /// [findOneOnOne] never does that on the pane's say-so, but here the user
  /// has asked to call this person, and an empty DM shows nothing to them.
  @override
  Future<String> callLink(
    ChatConversation conversation,
    ChatMember person, {
    required bool video,
  }) async {
    final user = person.userId;
    if (user == null || user.isEmpty) {
      throw ServerException(
          message: '${person.displayName} cannot be called from here.');
    }
    String? channel;
    if (conversation.kind == ChatKind.oneOnOne &&
        conversation.members.any((m) => m.userId == user)) {
      channel = conversation.id;
    }
    channel ??= _ims[teamId]?[user];
    if (channel == null) {
      await _memberships('im');
      channel = _ims[teamId]?[user];
    }
    if (channel == null) {
      final data = await _call('conversations.open',
          {'users': user, 'return_im': 'true'}, post: true);
      final opened = data['channel'];
      channel = opened is Map ? opened['id'] as String? : null;
      if (channel == null) {
        throw const ServerException(message: 'Slack opened no conversation.');
      }
      (_ims[teamId] ??= {})[user] = channel;
    }
    return 'https://app.slack.com/huddle/${Uri.encodeComponent(teamId)}/'
        '${Uri.encodeComponent(channel)}';
  }

  // ---- parsing ------------------------------------------------------------

  ChatConversation? _parseConversation(Map<String, dynamic> c, String? own) {
    final id = c['id'] as String?;
    if (id == null) return null;
    final latest = _ts(_latest['$teamId|$id']);
    if (c['is_im'] == true) {
      final user = c['user'] as String?;
      final name = user == null ? null : _users['$teamId|$user']?.name;
      return ChatConversation(
        id: id,
        kind: ChatKind.oneOnOne,
        title: name ?? 'Direct message',
        untitled: name == null,
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
      bodyHtml: messageHtml(m,
              userName: (id) => _users['$teamId|$id']?.name,
              customEmoji: (name) => _customEmoji[teamId]?[name]) +
          _imagesHtml(files),
      // A reply names its thread; a thread's parent names itself.
      replyToId: threadTs != null && threadTs != ts ? threadTs : null,
      editedAt: edited is Map ? _ts(edited['ts'] as String?) : null,
      isDeleted: subtype == 'tombstone' || subtype == 'message_deleted',
      isSystem: subtype != null && _systemSubtypes.contains(subtype),
      senderIsApp: user == null || subtype == 'bot_message' || m['bot_id'] != null,
      replyCount: (m['reply_count'] as num?)?.toInt(),
      latestReplyAt: _ts(m['latest_reply'] as String?),
      reactions: [
        for (final r in _list(m['reactions']))
          if (r['name'] is String)
            _reaction(r['name'] as String, r['count'], r['users']),
      ],
      attachmentNames: [
        for (final f in files)
          if (!_isImage(f) && (f['name'] as String?)?.isNotEmpty == true)
            f['name'] as String,
      ],
      editableText: editableTextOf(m),
    );
  }

  /// A message's text as the user typed it, for an edit, or null when plain
  /// text cannot say it again: a file, an attachment, layout blocks, or a
  /// mention, channel, `@here` or labelled link — sent text is escaped
  /// ([escapeText]), so each of those would come back as its raw markup.
  @visibleForTesting
  static String? editableTextOf(Map<String, dynamic> m) {
    if (_list(m['files']).isNotEmpty ||
        _list(m['attachments']).isNotEmpty ||
        _list(m['blocks']).any((b) => b['type'] != 'rich_text')) {
      return null;
    }
    final raw = m['text'] as String? ?? '';
    if (raw.trim().isEmpty) return null;
    // A bare link Slack linked itself (`<https://x>`, or labelled with its
    // own address) is just what was typed.
    final text = raw.replaceAllMapped(RegExp(r'<([^<>|]+)(?:\|([^<>]*))?>'),
        (m) {
      final target = m[1]!;
      final label = m[2];
      final shown = target.startsWith('mailto:') ? target.substring(7) : target;
      final isLink = target.startsWith('http://') ||
          target.startsWith('https://') ||
          target.startsWith('mailto:');
      return isLink && (label == null || label == shown || label == target)
          ? shown
          : '\u0000';
    });
    if (text.contains('\u0000')) return null;
    return text
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
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
      _imageSrc(f) != null;

  /// Which rendition of an uploaded picture to show. A GIF's `thumb_720` is
  /// a still of its first frame; `thumb_480_gif`/`thumb_360_gif` move, and
  /// the original does too.
  static String? _imageSrc(Map<String, dynamic> f) {
    final keys = f['mimetype'] == 'image/gif'
        ? const ['thumb_480_gif', 'thumb_360_gif', 'url_private']
        : const ['thumb_720', 'thumb_480', 'url_private'];
    for (final k in keys) {
      if (f[k] case final String url when url.isNotEmpty) return url;
    }
    return null;
  }

  /// Uploaded pictures after the text, from Slack's own thumbnails (still
  /// `files.slack.com`, so [image] fetches them with the token).
  static String _imagesHtml(List<Map<String, dynamic>> files) {
    final out = StringBuffer();
    for (final f in files.where(_isImage)) {
      final src = _imageSrc(f)!;
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

  static const _blocksFallback = 'This message contains interactive elements.';

  static List<Map<String, dynamic>> _list(Object? v) => v is List
      ? v.whereType<Map<String, dynamic>>().toList()
      : const [];

  /// A message's text, or — an app's message that has none — its first
  /// attachment's summary.
  static String _previewText(Map<String, dynamic> m) {
    final text = m['text'] as String? ?? '';
    final blocks = _list(m['blocks']);
    // Slack's own stand-in for a message of blocks it cannot put as text
    // (a table): the person's words around it say more.
    if (text.trim() == _blocksFallback) {
      final words = [
        for (final b in blocks)
          if (b['type'] == 'rich_text')
            for (final e in _list(b['elements']))
              for (final i in _list(e['elements']))
                if (i['text'] case final String t) t,
      ].join().trim();
      if (words.isNotEmpty) return escapeText(words);
      if (blocks.any((b) => b['type'] == 'table')) return 'Table';
    }
    if (text.trim().isNotEmpty) return text;
    final a = _list(m['attachments']).firstOrNull;
    for (final k in const ['fallback', 'pretext', 'title', 'text']) {
      if (a?[k] case final String s when s.trim().isNotEmpty) return s;
    }
    return text;
  }

  String _plain(String text) => replaceShortcodes(text)
      .replaceAllMapped(_mention,
          (m) => '@${_users['$teamId|${m[1]}']?.name ?? m[1]}')
      .replaceAllMapped(RegExp(r'<([^>|]+)\|([^>]+)>'), (m) => m[2]!)
      .replaceAllMapped(RegExp(r'<([^>]+)>'), (m) => m[1]!)
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  // ---- text ---------------------------------------------------------------

  /// What the user typed as Slack message text: [escapeText], with each of
  /// [mentions] still written as `@Name` turned into `<@U…>`.
  @visibleForTesting
  static String outgoingText(String text, List<ChatMember> mentions) => [
        for (final part in splitMentions(text, mentions))
          switch (part) {
            ChatTextRun(:final text) => escapeText(text),
            ChatMentionRun(:final member) => '<@${member.userId}>',
          },
      ].join();

  /// The conversation's members (`conversations.members`, the `*:read`
  /// already held), named from what is known. A handful not yet known are
  /// looked up one by one ([_resolveUsers]); a big channel's roster comes
  /// from `users.list` instead — 200 a call, once an hour — rather than a
  /// burst of `users.info`.
  @override
  Future<List<ChatMember>> mentionable(ChatConversation conversation) async {
    final ids = <String>[];
    String? cursor;
    for (var page = 0; page < 5; page++) {
      final data = await _call('conversations.members', {
        'channel': conversation.id,
        'limit': '200',
        'cursor': ?cursor,
      });
      ids.addAll((data['members'] as List? ?? const []).whereType<String>());
      cursor = (data['response_metadata'] as Map?)?['next_cursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    final missing =
        ids.where((id) => !_users.containsKey('$teamId|$id')).length;
    if (missing > 40) await _listUsers();
    await _resolveUsers(ids);
    return [
      for (final id in ids)
        if (_users['$teamId|$id'] case final u?)
          ChatMember(displayName: u.name, userId: id, email: u.email),
    ];
  }

  Future<void> _listUsers() async {
    final at = _usersListedAt[teamId];
    if (at != null && DateTime.now().difference(at) < const Duration(hours: 1)) {
      return;
    }
    _usersListedAt[teamId] = DateTime.now();
    String? cursor;
    for (var page = 0; page < 10; page++) {
      final data = await _call('users.list', {
        'limit': '200',
        'cursor': ?cursor,
      });
      for (final u in _list(data['members'])) {
        final id = u['id'] as String?;
        if (id == null || u['deleted'] == true) continue;
        _users['$teamId|$id'] = _SlackUser.fromJson(u);
      }
      cursor = (data['response_metadata'] as Map?)?['next_cursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
  }

  /// What the user typed, escaped the way Slack wants message text: only
  /// `&`, `<` and `>` (anything between `<` and `>` would otherwise be read
  /// as a link or mention). `*bold*` and the like pass through as mrkdwn.
  static String escapeText(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// A channel name as Slack will take it: lowercase, no `#`, whitespace as
  /// hyphens — what Slack's own rename box does as you type, rather than
  /// refusing "Team Updates" with `invalid_name_specials`.
  static String slackChannelName(String title) => title
      .trim()
      .replaceFirst(RegExp(r'^#+'), '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '-');

  /// Slack mrkdwn as the HTML `ChatMessageBody` renders.
  ///
  /// Slack sends `&`, `<` and `>` already escaped, so the only raw `<…>` in
  /// [text] are its control sequences: `<@U…>` mentions (named through
  /// [userName]), `<#C…|name>` channels, `<!here>` and friends, and
  /// `<url|label>` links. The rest is `*bold*`, `_italic_`, `~strike~`,
  /// `` `code` ``, ```` ```blocks``` ```` and `&gt; ` quotes.
  ///
  /// [customEmoji] answers the workspace's own `:names:` — a picture becomes
  /// an `<img data-emoji>` the renderer draws at text size.
  static String mrkdwnToHtml(
    String text, {
    String? Function(String userId)? userName,
    SlackCustomEmoji? Function(String name)? customEmoji,
  }) {
    final out = StringBuffer();
    var last = 0;
    for (final m in RegExp(r'<([^<>]+)>').allMatches(text)) {
      out.write(_format(text.substring(last, m.start), customEmoji));
      out.write(_control(m[1]!, userName));
      last = m.end;
    }
    out.write(_format(text.substring(last), customEmoji));
    return out.toString();
  }

  /// A whole message as the HTML `ChatMessageBody` renders: its text, or the
  /// layout blocks Slack shows in its place, then any attachments.
  ///
  /// An app's message (a CrowdStrike Falcon workflow, say) often carries
  /// only a headline in `text` — the notification fallback — and the detail
  /// in `blocks` or in `attachments`, each of which may hold blocks of its
  /// own. A person's message is a single `rich_text` block saying what its
  /// text does, so text stays the source whenever it has any and every block
  /// is `rich_text`.
  static String messageHtml(
    Map<String, dynamic> m, {
    String? Function(String userId)? userName,
    SlackCustomEmoji? Function(String name)? customEmoji,
  }) {
    String md(String s) =>
        mrkdwnToHtml(s, userName: userName, customEmoji: customEmoji);
    final text = m['text'] as String? ?? '';
    final blocks = _list(m['blocks']);
    final useBlocks = blocks.isNotEmpty &&
        (text.trim().isEmpty || blocks.any((b) => b['type'] != 'rich_text'));
    var body = useBlocks ? _blocksHtml(blocks, md, userName, customEmoji) : '';
    if (body.isEmpty) body = md(text);
    final parts = [
      body,
      for (final a in _list(m['attachments']))
        _attachmentHtml(a, md, userName, customEmoji),
    ].where((s) => s.isNotEmpty).toList();
    // A plain message stays exactly the HTML its text makes.
    if (parts.length <= 1) return parts.firstOrNull ?? '';
    return parts.map((s) => '<div>$s</div>').join();
  }

  /// A legacy attachment: its blocks when it has them, else `pretext`, a
  /// `title` (linked), `text` and `title: value` fields.
  static String _attachmentHtml(
    Map<String, dynamic> a,
    String Function(String) md,
    String? Function(String userId)? userName,
    SlackCustomEmoji? Function(String name)? customEmoji,
  ) {
    final blocks = _list(a['blocks']);
    if (blocks.isNotEmpty) {
      final html = _blocksHtml(blocks, md, userName, customEmoji);
      if (html.isNotEmpty) return html;
    }
    String? str(String k) {
      final v = a[k];
      return v is String && v.trim().isNotEmpty ? v : null;
    }

    final title = str('title');
    final link = str('title_link');
    return [
      if (str('pretext') case final p?) md(p),
      if (str('author_name') case final n?) '<b>${md(n)}</b>',
      if (title != null)
        link != null &&
                (link.startsWith('https://') || link.startsWith('http://'))
            ? '<b><a href="${_escape(link)}">${md(title)}</a></b>'
            : '<b>${md(title)}</b>',
      if (str('text') case final t?) md(t),
      for (final f in _list(a['fields']))
        if (f['title'] is String || f['value'] is String)
          [
            if (f['title'] case final String t when t.isNotEmpty)
              '<b>${md(t)}</b>',
            if (f['value'] case final String v when v.isNotEmpty) md(v),
          ].join(': '),
      if (str('footer') case final f?) '<i>${md(f)}</i>',
      // An unfurled picture or GIF (a pasted Giphy link, the older /giphy).
      ?_imgHtml(str('image_url'), str('fallback'), a['image_width'],
          a['image_height']),
      // Nothing above, but a summary of itself: better than nothing.
      if (title == null &&
          str('text') == null &&
          str('pretext') == null &&
          _list(a['fields']).isEmpty)
        if (str('fallback') case final f?) md(f),
    ].map((s) => '<div>$s</div>').join();
  }

  /// Block Kit as the renderer's HTML: one `<div>` per block. Dividers,
  /// inputs, buttons without a link and a context block's icons have
  /// nothing to say here; an `image` block (a /giphy GIF) is its picture.
  static String _blocksHtml(
    List<Map<String, dynamic>> blocks,
    String Function(String) md,
    String? Function(String userId)? userName,
    SlackCustomEmoji? Function(String name)? customEmoji,
  ) {
    String textObject(Object? t) {
      if (t is! Map) return '';
      final s = t['text'];
      if (s is! String || s.isEmpty) return '';
      return t['type'] == 'mrkdwn'
          ? md(s)
          : _escape(_unescape(s)).replaceAll('\n', '<br>');
    }

    final out = <String>[];
    for (final b in blocks) {
      final html = switch (b['type']) {
        'section' => [
            textObject(b['text']),
            for (final f in _list(b['fields'])) textObject(f),
          ].where((s) => s.isNotEmpty).join('<br>'),
        'header' => switch (textObject(b['text'])) {
            '' => '',
            final h => '<b>$h</b>',
          },
        'context' => [
            for (final e in _list(b['elements'])) textObject(e),
          ].where((s) => s.isNotEmpty).join(' '),
        'actions' => [
            for (final e in _list(b['elements']))
              if (e['url'] case final String url
                  when url.startsWith('https://') || url.startsWith('http://'))
                '<a href="${_escape(url)}">'
                    '${switch (textObject(e['text'])) {
                  '' => _escape(url),
                  final t => t,
                }}</a>',
          ].join(' · '),
        'rich_text' => _richTextHtml(_list(b['elements']), userName, customEmoji),
        'markdown' => b['text'] is String ? md(b['text'] as String) : '',
        'table' => _tableHtml(
            b['rows'] is List ? b['rows'] as List : const [],
            userName,
            customEmoji),
        'image' => _imgHtml(
              b['image_url'] as String? ??
                  (b['slack_file'] as Map?)?['url'] as String?,
              b['alt_text'] as String?,
              b['image_width'],
              b['image_height'],
            ) ??
            '',
        _ => '',
      };
      if (html.isNotEmpty) out.add('<div>$html</div>');
    }
    return out.join();
  }

  /// A `table` block (a table a person drew in Slack's composer): rows of
  /// `raw_text` or `rich_text` cells, the first row as the header, as Slack
  /// shows it. The message's `text` is only Slack's "This message contains
  /// interactive elements." fallback, so without this the table was lost.
  static String _tableHtml(
    List<Object?> rows,
    String? Function(String userId)? userName,
    SlackCustomEmoji? Function(String name)? customEmoji,
  ) {
    if (rows.isEmpty) return '';
    final out = StringBuffer('<table>');
    for (final (i, row) in rows.indexed) {
      final tag = i == 0 && rows.length > 1 ? 'th' : 'td';
      out.write('<tr>');
      for (final c in _list(row)) {
        final html = switch (c['type']) {
          'rich_text' =>
            _richTextHtml(_list(c['elements']), userName, customEmoji),
          _ => _escape(c['text'] as String? ?? '').replaceAll('\n', '<br>'),
        };
        out.write('<$tag>$html</$tag>');
      }
      out.write('</tr>');
    }
    out.write('</table>');
    return out.toString();
  }

  /// An `<img>` for a picture Slack names by URL — https only (anything
  /// else would go out unencrypted, and [image] refuses it anyway) — sized
  /// when Slack says how big it is, so the placeholder holds its shape.
  static String? _imgHtml(String? src, String? alt, Object? w, Object? h) {
    if (src == null || !src.startsWith('https://')) return null;
    final size = w is num && h is num && w > 0 && h > 0
        ? ' width="${w.toInt()}" height="${h.toInt()}"'
        : '';
    return '<img src="${_escape(src)}" alt="${_escape(alt ?? 'image')}"$size>';
  }

  /// A `rich_text` block's sections, lists, quotes and code. Its text, unlike
  /// mrkdwn, arrives unescaped.
  static String _richTextHtml(
    List<Map<String, dynamic>> elements,
    String? Function(String userId)? userName,
    SlackCustomEmoji? Function(String name)? customEmoji,
  ) {
    String inline(List<Map<String, dynamic>> items) {
      final out = StringBuffer();
      for (final e in items) {
        final style = e['style'] is Map ? e['style'] as Map : const {};
        var html = switch (e['type']) {
          'text' => _escape(e['text'] as String? ?? ''),
          'link' => switch (e['url']) {
              final String url
                  when url.startsWith('https://') ||
                      url.startsWith('http://') ||
                      url.startsWith('mailto:') =>
                '<a href="${_escape(url)}">'
                    '${_escape((e['text'] as String?) ?? url)}</a>',
              _ => _escape(e['text'] as String? ?? ''),
            },
          'user' => switch (e['user_id']) {
              final String id =>
                '<b>@${_escape(userName?.call(id) ?? id)}</b>',
              _ => '',
            },
          'channel' => '<b>#channel</b>',
          'usergroup' => '<b>@group</b>',
          'broadcast' => '<b>@${_escape(e['range'] as String? ?? 'here')}</b>',
          'emoji' => switch (e['name']) {
              final String name => shortcodeEmoji(name) ??
                  customEmoji?.call(name)?.text ??
                  (e['unicode'] is String
                      ? String.fromCharCodes([
                          for (final cp in (e['unicode'] as String).split('-'))
                            int.tryParse(cp, radix: 16) ?? 0x3F,
                        ])
                      : ':${_escape(name)}:'),
              _ => '',
            },
          'date' => _escape(e['fallback'] as String? ?? ''),
          _ => _escape(e['text'] as String? ?? ''),
        };
        if (style['code'] == true) html = '<code>$html</code>';
        if (style['bold'] == true) html = '<b>$html</b>';
        if (style['italic'] == true) html = '<i>$html</i>';
        if (style['strike'] == true) html = '<s>$html</s>';
        out.write(html);
      }
      return out.toString().replaceAll('\n', '<br>');
    }

    final out = StringBuffer();
    for (final e in elements) {
      final items = _list(e['elements']);
      switch (e['type']) {
        case 'rich_text_section':
          out.write('<div>${inline(items)}</div>');
        case 'rich_text_list':
          final tag = e['style'] == 'ordered' ? 'ol' : 'ul';
          out.write('<$tag>');
          for (final item in items) {
            out.write('<li>${inline(_list(item['elements']))}</li>');
          }
          out.write('</$tag>');
        case 'rich_text_quote':
          out.write('<blockquote>${inline(items)}</blockquote>');
        case 'rich_text_preformatted':
          out.write('<pre>${inline(items)}</pre>');
      }
    }
    return out.toString();
  }

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

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

  static String _format(
      String text, SlackCustomEmoji? Function(String name)? customEmoji) {
    if (text.isEmpty) return text;
    // Shortcodes first, while code is still marked by its backticks. A
    // custom emoji's <img> waits behind a placeholder, so the formatting
    // below never reads an underscore in its URL as italics.
    final images = <String>[];
    var html = replaceShortcodes(text, custom: (name) {
      final e = customEmoji?.call(name);
      if (e == null) return null;
      if (e.text != null) return e.text;
      images.add('<img data-emoji="1" src="${_escape(e.url!)}" '
          'alt=":${_escape(name)}:">');
      return '\u{E000}${images.length - 1}\u{E001}';
    });
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
    if (images.isNotEmpty) {
      html = html.replaceAllMapped(RegExp('\u{E000}(\\d+)\u{E001}'),
          (m) => images[int.parse(m[1]!)]);
    }
    // The renderer collapses whitespace, a code block's included.
    return html.replaceAll('\n', '<br>');
  }

  /// A reaction by Slack's name for it: standard (`+1`, `wave::skin-tone-2`),
  /// or the workspace's own, shown as its picture.
  ChatReaction _reaction(String name, Object? count, Object? users) {
    final n = (count as num?)?.toInt() ?? 1;
    // Slack lists some of who reacted (all, for a handful).
    final ids = [
      for (final u in users is List ? users : const []) if (u is String) u,
    ];
    final standard = shortcodeEmoji(name);
    if (standard != null) {
      return ChatReaction(emoji: standard, count: n, userIds: ids);
    }
    final custom = _customEmoji[teamId]?[name.split('::').first];
    return ChatReaction(
      emoji: custom?.text ?? ':$name:',
      count: n,
      imageUrl: custom?.url,
      userIds: ids,
    );
  }

  /// The workspace's own emoji, at most once per [_customEmojiFresh]. Best
  /// effort: a token from before `emoji:read` was asked for (or any other
  /// failure) leaves names as `:name:` text rather than failing the read.
  Future<void> _loadCustomEmoji() async {
    final at = _customEmojiAt[teamId];
    if (at != null && DateTime.now().difference(at) < _customEmojiFresh) {
      return;
    }
    _customEmojiAt[teamId] = DateTime.now();
    try {
      final data = await _call('emoji.list', const {});
      _customEmoji[teamId] = resolveCustomEmoji(
          (data['emoji'] as Map?)?.cast<String, Object?>() ?? const {});
    } on SlackReconnectException {
      rethrow;
    } catch (e) {
      debugPrint('[Slack] no custom emoji for $teamId: $e');
      _customEmoji[teamId] ??= const {};
    }
  }

  /// `emoji.list`'s answer — a URL per name, or `alias:other` — with every
  /// alias followed to a picture or to a standard emoji's characters.
  @visibleForTesting
  static Map<String, SlackCustomEmoji> resolveCustomEmoji(
      Map<String, Object?> raw) {
    SlackCustomEmoji? resolve(String name, int depth) {
      final v = raw[name];
      if (v is String && v.startsWith('alias:')) {
        if (depth > 4) return null;
        final target = v.substring(6);
        final standard = shortcodeEmoji(target);
        return standard != null
            ? SlackCustomEmoji(text: standard)
            : resolve(target, depth + 1);
      }
      if (v is String && v.startsWith('https://')) {
        return SlackCustomEmoji(url: v);
      }
      return null;
    }

    return {
      for (final name in raw.keys)
        if (resolve(name, 0) case final e?) name: e,
    };
  }

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
        // Custom emoji and marking a channel read are extras: a token
        // granted before `emoji:read` or `channels:write` was asked for
        // keeps working, just without them.
        if ((method == 'emoji.list' ||
                method == 'conversations.mark' ||
                method == 'conversations.rename' ||
                method == 'reactions.add' ||
                method == 'reactions.remove' ||
                method == 'files.getUploadURLExternal' ||
                method == 'files.completeUploadExternal') &&
            error == 'missing_scope') {
          throw SlackApiException(error);
        }
        if ((method == 'reactions.add' && error == 'already_reacted') ||
            (method == 'reactions.remove' && error == 'no_reaction')) {
          throw SlackApiException(error);
        }
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
        'name_taken' => 'A Slack channel already has that name.',
        'invalid_name_required' => 'A Slack channel needs a name.',
        'invalid_name_maxlength' =>
          'Slack channel names are at most 80 characters.',
        'invalid_name' ||
        'invalid_name_specials' ||
        'invalid_name_punctuation' =>
          'Slack channel names can only have lowercase letters, numbers, '
              'hyphens and underscores.',
        _ => 'Slack: $error',
      };
}

/// A workspace's own emoji: a picture, or — an alias of a standard one —
/// the characters.
class SlackCustomEmoji {
  const SlackCustomEmoji({this.url, this.text});

  final String? url;
  final String? text;
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
