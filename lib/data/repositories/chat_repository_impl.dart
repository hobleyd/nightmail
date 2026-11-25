import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../core/utils/latest_reply.dart' show htmlToPlainText;
import '../../domain/entities/chat.dart';
import '../../core/utils/consumer_email_domain.dart';
import '../../domain/repositories/chat_repository.dart';
import '../../domain/repositories/contact_cache_repository.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../infrastructure/slack/slack_workspaces.dart';
import '../datasources/local/chat_local_datasource.dart';
import '../datasources/remote/chat_remote_datasource.dart';
import '../datasources/remote/slack_chat_datasource.dart';

class ChatRepositoryImpl implements ChatRepository {
  ChatRepositoryImpl({
    required AccountManager accountManager,
    required ContactCacheRepository contacts,
    required this._slack,
    required this._local,
  })  : _accounts = accountManager,
        _contacts = contacts;

  final AccountManager _accounts;
  final ContactCacheRepository _contacts;
  final SlackWorkspaces _slack;
  final ChatLocalDatasource _local;

  /// The datasource behind a chat id: a Slack workspace for `slack:{team}`,
  /// otherwise the email account's own chat (null where it has none).
  ChatRemoteDatasource? _ds(String accountId) {
    final team = SlackWorkspace.teamIdOf(accountId);
    if (team != null) {
      return SlackChatDatasource(workspaces: _slack, teamId: team);
    }
    return _accounts.chatDatasourceForAccount(accountId);
  }

  @override
  Future<List<ChatSource>> sources(String? accountId) async {
    final out = <ChatSource>[];
    final account = accountId == null ? null : _accounts.accountById(accountId);
    if (account != null && await _accounts.chatGrants(account.id) != null) {
      final server = account is MicrosoftAccount && account.isNightmailServer;
      out.add(ChatSource(
        id: account.id,
        kind: account is GmailAccount
            ? ChatSourceKind.googleChat
            : server
                ? ChatSourceKind.nightmailServer
                : ChatSourceKind.teams,
        label: account is GmailAccount
            ? 'Google Chat'
            : server
                ? 'NightMail Chat'
                : 'Teams',
      ));
    }
    final workspaces = await _slack.all();
    for (final w in workspaces) {
      out.add(ChatSource(
        id: w.chatId,
        kind: ChatSourceKind.slack,
        label: 'Slack · ${w.teamName}',
        needsReconnect: w.needsReconnect,
        missingScopes: !w.hasAllScopes,
      ));
    }
    return out;
  }

  @override
  Stream<void> get sourcesChanged => _slack.changes;

  @override
  Future<Either<Failure, ChatSource>> connectSlack(String clientId) async {
    try {
      final w = await _slack.connect(clientId: clientId);
      _conversations.remove(w.chatId);
      return Right(ChatSource(
        id: w.chatId,
        kind: ChatSourceKind.slack,
        label: 'Slack · ${w.teamName}',
      ));
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<void> disconnectSlack(String sourceId) async {
    final team = SlackWorkspace.teamIdOf(sourceId);
    if (team == null) return;
    await forgetAccount(sourceId);
    await _slack.remove(team);
  }

  @override
  Future<String?> slackClientId(String sourceId) async {
    final team = SlackWorkspace.teamIdOf(sourceId);
    if (team == null) return null;
    return (await _slack.byTeam(team))?.clientId;
  }

  /// The last conversation list per account, so the pane can look a person's
  /// one-on-one up on every selected email without listing chats each time.
  final _conversations = <String, List<ChatConversation>>{};
  final _listedAt = <String, DateTime>{};

  /// Channel activity learned so far, kept across list refreshes (a channel
  /// listing does not carry it).
  final _channelActivity = <String, ChatConversation>{};

  /// How long [findOneOnOne] trusts the cached list.
  static const _listFresh = Duration(minutes: 2);

  /// How many conversations a NightMail Server search reads, and how far
  /// back in each: it has no `/search/query`, so search is a scan of recent
  /// history. Two pages of fifty in the twenty most recent conversations.
  static const _scanConversations = 20;
  static const _scanPages = 2;

  @override
  Future<ChatAccess> access(String accountId) async {
    final team = SlackWorkspace.teamIdOf(accountId);
    if (team != null) {
      final w = await _slack.byTeam(team);
      if (w == null) return ChatAccess.unsupported;
      // Reconnecting is the consent prompt's job, as Microsoft's is.
      return w.needsReconnect ? ChatAccess.needsConsent : ChatAccess.full;
    }
    final grants = await _accounts.chatGrants(accountId);
    return _accessOf(grants);
  }

  static ChatAccess _accessOf(({bool chats, bool channels})? grants) =>
      switch (grants) {
        null => ChatAccess.unsupported,
        (chats: false, channels: _) => ChatAccess.needsConsent,
        (chats: true, channels: false) => ChatAccess.chatsOnly,
        (chats: true, channels: true) => ChatAccess.full,
      };

  @override
  Future<Either<Failure, ChatAccess>> requestAccess(
    String accountId, {
    bool channels = false,
  }) async {
    final team = SlackWorkspace.teamIdOf(accountId);
    if (team != null) {
      final clientId = (await _slack.byTeam(team))?.clientId;
      if (clientId == null) {
        return const Left(
            UnsupportedFailure(message: 'This Slack workspace is not connected.'));
      }
      final connected = await connectSlack(clientId);
      return connected.flatMap((s) => s.id == accountId
          ? const Right(ChatAccess.full)
          : Left(AuthFailure(
              message: 'That sign-in was to ${s.label.replaceFirst('Slack · ', '')}, '
                  'not this workspace.')));
    }
    try {
      final grants =
          await _accounts.requestChatAccess(accountId, channels: channels);
      _conversations.remove(accountId);
      return Right(_accessOf(grants));
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, List<ChatConversation>>> conversations(
    String accountId, {
    bool refresh = false,
  }) =>
      _guard(accountId, (ds) async {
        final cached = _conversations[accountId];
        if (!refresh && cached != null) return cached;
        final access = await this.access(accountId);
        final chats = await ds.listChats();
        var channels = const <ChatConversation>[];
        if (access == ChatAccess.full) {
          try {
            channels = await ds.listChannels();
          } on ServerException catch (e) {
            // Channels refused (no Teams licence, tenant policy) leave chats.
            debugPrint('[Chat] channels unavailable: $e');
          }
        }
        // Channels list without activity, and Slack lists nothing with it:
        // whatever has been learned of either is kept across refreshes —
        // this session's first, then what the cache on disk last knew.
        final known = await _cachedActivity(accountId);
        final merged = [
          for (final c in [...chats, ...channels])
            if (c.lastActivity != null)
              c
            else if (_channelActivity['$accountId|${c.key}']
                case final learned?)
              _withLearned(c, learned)
            else
              _withActivityOf(c, known[c.key]),
        ]..sort(_byActivity);
        _conversations[accountId] = merged;
        _listedAt[accountId] = DateTime.now();
        _saveList(accountId);
        return merged;
      });

  /// Activity the cache on disk holds for [accountId]'s conversations, by
  /// key — read once per session, for conversations a listing gives none.
  final _diskActivity = <String, Map<String, ChatConversation>>{};

  Future<Map<String, ChatConversation>> _cachedActivity(
      String accountId) async {
    final known = _diskActivity[accountId];
    if (known != null) return known;
    final cached = await _readCachedList(accountId);
    return _diskActivity[accountId] = {
      for (final c in cached)
        if (c.lastActivity != null) c.key: c,
    };
  }

  /// [c] as listed, with the activity and preview [known] last had.
  /// [c] as listed — its title and members current, a rename included —
  /// with the activity [learned] looked up for it.
  static ChatConversation _withLearned(
          ChatConversation c, ChatConversation learned) =>
      c.copyWith(
        lastActivity: learned.lastActivity,
        lastMessagePreview: learned.lastMessagePreview,
        noMessages: learned.noMessages,
      );

  static ChatConversation _withActivityOf(
          ChatConversation c, ChatConversation? known) =>
      known == null
          ? c
          : c.copyWith(
              lastActivity: known.lastActivity,
              lastMessagePreview: known.lastMessagePreview,
            );

  Future<List<ChatConversation>> _readCachedList(String accountId) async {
    try {
      return await _local.conversations(accountId);
    } catch (e) {
      debugPrint('[Chat] cached list unreadable: $e');
      return const [];
    }
  }

  @override
  Future<List<ChatConversation>> cachedConversations(String accountId) async =>
      _conversations[accountId] ?? await _readCachedList(accountId);

  /// Pending writes of each account's list. Activity arrives a few
  /// conversations at a time, so a write waits for the burst to settle
  /// rather than encrypting the whole list for each.
  final _listSaves = <String, Timer>{};
  static const _listSaveDelay = Duration(seconds: 2);

  void _saveList(String accountId) {
    _listSaves.remove(accountId)?.cancel();
    _listSaves[accountId] = Timer(_listSaveDelay, () async {
      _listSaves.remove(accountId);
      final list = _conversations[accountId];
      if (list == null) return;
      try {
        await _local.saveConversations(accountId, list);
      } catch (e) {
        debugPrint('[Chat] could not cache the list: $e');
      }
    });
  }

  static int _byActivity(ChatConversation a, ChatConversation b) {
    final at = a.lastActivity, bt = b.lastActivity;
    if (at == null && bt == null) return a.title.compareTo(b.title);
    if (at == null) return 1;
    if (bt == null) return -1;
    return bt.compareTo(at);
  }

  @override
  Future<Either<Failure, ChatConversation>> channelActivity(
    String accountId,
    ChatConversation conversation,
  ) =>
      _guard(accountId, (ds) async {
        final updated = await ds.channelActivity(conversation);
        _channelActivity['$accountId|${conversation.key}'] = updated;
        final list = _conversations[accountId];
        if (list != null) {
          _conversations[accountId] = [
            for (final c in list)
              c.key == updated.key ? _withLearned(c, updated) : c,
          ]..sort(_byActivity);
          _saveList(accountId);
        }
        return updated;
      });

  @override
  Future<int> unreadCount(String accountId) async =>
      (await unreadConversations(accountId)).length;

  @override
  Future<List<ChatConversation>> unreadConversations(String accountId) async {
    final access = await this.access(accountId);
    if (access != ChatAccess.chatsOnly && access != ChatAccess.full) {
      return const [];
    }
    final recent = await _guard(accountId, (ds) => ds.listRecentChats());
    final unread = recent.match((f) {
      debugPrint('[Chat] unread check failed: ${f.message}');
      return const <ChatConversation>[];
    }, (chats) => chats.where((c) {
      if (!c.unread) return false;
      // Microsoft's read state can trail a mark by a moment; a chat marked
      // here stays read until something newer arrives in it.
      final marked = _markedAt['$accountId|${c.key}'];
      final at = c.lastActivity;
      return marked == null || (at != null && at.isAfter(marked));
    }).toList());
    if (unread.isEmpty) return unread;
    // The recent listing has no members, so a one-on-one is untitled there:
    // the full list — this session's or the cached one — names it.
    final known = {
      for (final c in _conversations[accountId] ??
          await _readCachedList(accountId))
        c.key: c,
    };
    return [
      for (final c in unread)
        if (known[c.key] case final k?)
          ChatConversation(
            id: k.id,
            kind: k.kind,
            title: k.title,
            teamId: k.teamId,
            teamName: k.teamName,
            lastActivity: c.lastActivity ?? k.lastActivity,
            lastMessagePreview: c.lastMessagePreview ?? k.lastMessagePreview,
            members: k.members,
            threaded: k.threaded,
            unread: true,
          )
        else
          c,
    ];
  }

  /// When [markRead] last ran per `account|conversation`.
  final _markedAt = <String, DateTime>{};

  final _reads = StreamController<String>.broadcast();

  @override
  Stream<String> get reads => _reads.stream;

  final _readKeys =
      StreamController<({String accountId, String key, bool here})>.broadcast();

  @override
  Stream<({String accountId, String key, bool here})> get readKeys =>
      _readKeys.stream;

  /// Not on [reads]: what listens there re-polls every system, and the
  /// listeners of [readKeys] can drop the one conversation instead.
  @override
  void readElsewhere(String accountId, String key) {
    _markedAt['$accountId|$key'] = DateTime.now();
    _countRead(accountId, key);
    _readKeys.add((accountId: accountId, key: key, here: false));
  }

  void _countRead(String accountId, String key) {
    final list = _conversations[accountId];
    if (list != null) {
      _conversations[accountId] = [
        for (final c in list) c.key == key ? c.copyWith(unread: false) : c,
      ];
    }
  }

  @override
  Future<void> markRead(
    String accountId,
    ChatConversation conversation,
  ) async {
    if (conversation.isChannel) return;
    _markedAt['$accountId|${conversation.key}'] = DateTime.now();
    final done = await _guard(accountId, (ds) => ds.markRead(conversation));
    done.match(
      (f) => debugPrint('[Chat] mark read failed: ${f.message}'),
      (_) {},
    );
    _countRead(accountId, conversation.key);
    _reads.add(accountId);
    _readKeys.add((accountId: accountId, key: conversation.key, here: true));
  }

  @override
  Future<String?> ownUserId(
    String accountId, {
    ChatConversation? conversation,
  }) async {
    final ds = _ds(accountId);
    if (ds == null) return null;
    try {
      return await ds.ownUserId(conversation);
    } catch (e) {
      debugPrint('[Chat] own id unavailable: $e');
      return null;
    }
  }

  @override
  Future<Either<Failure, ChatConversation?>> findOneOnOne(
    String accountId,
    String email, {
    String name = '',
  }) async {
    final direct = _ds(accountId);
    if (direct != null && direct.findsOneOnOneDirectly) {
      return _guard(accountId, (ds) => ds.findOneOnOne(email));
    }
    final listedAt = _listedAt[accountId];
    final stale = listedAt == null ||
        DateTime.now().difference(listedAt) > _listFresh;
    // A one-on-one's id never changes, so one the list already holds — this
    // session's, or the cache on disk after a restart — opens at once and
    // the listing refreshes behind it. Only a miss waits for the server: the
    // chat may be new.
    final known = _conversations[accountId] ??
        await _readCachedList(accountId);
    final hit = _matchOneOnOne(known, email, name);
    if (hit != null) {
      if (stale) unawaited(conversations(accountId, refresh: true));
      return Right(hit);
    }
    final listed = await conversations(accountId, refresh: stale);
    return listed.map((all) => _matchOneOnOne(all, email, name));
  }

  static ChatConversation? _matchOneOnOne(
      List<ChatConversation> all, String email, String name) {
    final wanted = email.trim().toLowerCase();
    final oneOnOnes = all.where((c) => c.kind == ChatKind.oneOnOne);
    for (final c in oneOnOnes) {
      if (c.members.any((m) => m.email == wanted)) return c;
    }
    // Teams lists a federated user without an address; fall back to their
    // name, but never guess between two people who share it.
    final wantedName = name.trim().toLowerCase();
    if (wantedName.isEmpty) return null;
    final byName = [
      for (final c in oneOnOnes)
        if (c.members.any((m) =>
            (m.email == null || m.email!.isEmpty) &&
            m.displayName.trim().toLowerCase() == wantedName))
          c,
    ];
    return byName.length == 1 ? byName.single : null;
  }

  @override
  Future<Either<Failure, ChatMessagePage>> messages(
    String accountId,
    ChatConversation conversation, {
    String? nextLink,
  }) =>
      _guard(accountId,
          (ds) => ds.messages(conversation, cursor: nextLink));

  /// Accounts whose server refused a delta: asked for full pages from then
  /// on, rather than refused again every poll.
  final _noDelta = <String>{};

  @override
  Future<Either<Failure, ChatMessageDelta?>> messagesSince(
    String accountId,
    ChatConversation conversation,
    DateTime since,
  ) {
    if (_noDelta.contains(accountId)) return Future.value(const Right(null));
    return _guard(accountId, (ds) async {
      try {
        return await ds.messagesSince(conversation, since);
      } on SlackReconnectException {
        rethrow;
      } on ServerException catch (e) {
        final refused = e.statusCode == 400 ||
            e.statusCode == 405 ||
            e.statusCode == 501;
        if (!refused) rethrow;
        debugPrint('[Chat] no deltas for $accountId: $e');
        _noDelta.add(accountId);
        return null;
      }
    });
  }

  @override
  Future<List<ChatMessage>> cachedMessages(
    String accountId,
    ChatConversation conversation,
  ) async {
    try {
      return await _local.messages(accountId, conversation.key);
    } catch (e) {
      debugPrint('[Chat] cached messages unreadable: $e');
      return const [];
    }
  }

  @override
  Future<void> cacheMessages(
    String accountId,
    ChatConversation conversation,
    List<ChatMessage> messages,
  ) async {
    try {
      await _local.saveMessages(accountId, conversation.key, messages);
    } catch (e) {
      debugPrint('[Chat] could not cache messages: $e');
    }
  }

  @override
  Future<void> forgetAccount(String accountId) async {
    _listSaves.remove(accountId)?.cancel();
    _conversations.remove(accountId);
    _listedAt.remove(accountId);
    _diskActivity.remove(accountId);
    _noDelta.remove(accountId);
    _channelActivity.removeWhere((k, _) => k.startsWith('$accountId|'));
    try {
      await _local.clear(accountId);
    } catch (e) {
      debugPrint('[Chat] could not clear the cache: $e');
    }
  }

  @override
  Future<Either<Failure, List<ChatMessage>>> replies(
    String accountId,
    ChatConversation conversation,
    ChatMessage post,
  ) =>
      _guard(accountId, (ds) => ds.replies(conversation, post));

  @override
  Future<Either<Failure, ChatMessage>> sendMessage(
    String accountId,
    ChatConversation conversation,
    String text, {
    ChatMessage? replyTo,
    ChatOutgoingImage? image,
  }) =>
      _guard(accountId, (ds) async {
        final sent = await ds.send(conversation, text,
            replyTo: replyTo, image: image);
        if (image != null) _seedImage(accountId, sent, image.bytes);
        _touch(accountId, conversation, sent);
        return sent;
      });

  @override
  bool canSendImage(String accountId, ChatConversation conversation) =>
      _ds(accountId)?.canSendImage(conversation) ?? false;

  /// The picture just sent, under the `src` its echo shows it by. Google and
  /// Slack process an upload after answering, so fetching it at once can
  /// miss — and a miss stays a miss until restart.
  void _seedImage(String accountId, ChatMessage sent, Uint8List bytes) {
    final srcs = [
      for (final m in _imgTag.allMatches(sent.bodyHtml))
        if (!m[0]!.contains('data-emoji')) _unescapeAttr(m[1]!),
    ];
    if (srcs.length != 1) return;
    _images.remove('$accountId|img|${srcs.single}');
    _cachedImage('$accountId|img|${srcs.single}', () => Future.value(bytes));
  }

  static final _imgTag = RegExp(r'<img\b[^>]*?\bsrc="([^"]*)"[^>]*>');

  static String _unescapeAttr(String s) => s
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  @override
  bool canEdit(String accountId, ChatConversation conversation) =>
      _ds(accountId)?.canEdit(conversation) ?? false;

  @override
  Future<Either<Failure, ChatMessage>> editMessage(
    String accountId,
    ChatConversation conversation,
    ChatMessage message,
    String text,
  ) =>
      _guard(accountId, (ds) async {
        final edited = await ds.edit(conversation, message, text);
        _retouch(accountId, conversation, edited);
        return edited;
      });

  @override
  bool canThread(String accountId, ChatConversation conversation) =>
      _ds(accountId)?.canThread(conversation) ?? conversation.hasThreads;

  @override
  bool canReact(String accountId, ChatConversation conversation) =>
      _ds(accountId)?.canReact(conversation) ?? false;

  @override
  Future<Either<Failure, bool>> react(
    String accountId,
    ChatConversation conversation,
    ChatMessage message,
    String emoji,
  ) =>
      _guard(accountId, (ds) => ds.react(conversation, message, emoji));

  @override
  Future<Either<Failure, bool>> unreact(
    String accountId,
    ChatConversation conversation,
    ChatMessage message,
    String emoji,
  ) =>
      _guard(accountId, (ds) => ds.unreact(conversation, message, emoji));

  @override
  bool canRename(String accountId, ChatConversation conversation) =>
      _ds(accountId)?.canRename(conversation) ?? false;

  @override
  Future<Either<Failure, ChatConversation>> renameConversation(
    String accountId,
    ChatConversation conversation,
    String title,
  ) =>
      _guard(accountId, (ds) async {
        final renamed = await ds.rename(conversation, title);
        final list = _conversations[accountId];
        if (list != null && list.any((x) => x.key == renamed.key)) {
          _conversations[accountId] = [
            for (final x in list)
              x.key == renamed.key ? x.copyWith(title: renamed.title) : x,
          ];
          _saveList(accountId);
        }
        return renamed;
      });

  @override
  Future<Either<Failure, (ChatConversation, ChatMessage)>> startOneOnOne(
    String accountId,
    String email,
    String displayName,
    String text,
  ) =>
      _guard(accountId, (ds) async {
        // Slack opens a DM by user id; it needs no address of the user's.
        final own = SlackWorkspace.teamIdOf(accountId) != null
            ? ''
            : _accounts.chatOwnAddress(accountId);
        if (own == null ||
            (own.isEmpty && SlackWorkspace.teamIdOf(accountId) == null)) {
          throw const ServerException(
              message: 'This account has no address to chat as.');
        }
        final ChatConversation chat;
        try {
          chat = await ds.createOneOnOne(
            ownEmail: own,
            email: email,
            displayName: displayName,
          );
        } on ServerException catch (e) {
          if (e.statusCode == 400 || e.statusCode == 404) {
            throw ServerException(
              message: '$email is not in your organisation\'s directory, so '
                  'a chat cannot be started with them.',
              statusCode: e.statusCode,
            );
          }
          rethrow;
        }
        final sent = await ds.send(chat, text);
        _conversations[accountId] = [
          chat,
          ...?_conversations[accountId]?.where((c) => c.key != chat.key),
        ];
        _touch(accountId, chat, sent);
        return (chat, sent);
      });

  /// The list's preview of [c] follows an edit of its newest message; its
  /// place in the list does not move.
  void _retouch(String accountId, ChatConversation c, ChatMessage edited) {
    final list = _conversations[accountId];
    if (list == null) return;
    final i = list.indexWhere((x) => x.key == c.key);
    final last = i < 0 ? null : list[i].lastActivity;
    if (last == null || last.isAfter(edited.createdAt)) return;
    _conversations[accountId] = [
      ...list.take(i),
      list[i].copyWith(lastMessagePreview: htmlToPlainText(edited.bodyHtml)),
      ...list.skip(i + 1),
    ];
    _saveList(accountId);
  }

  void _touch(String accountId, ChatConversation c, ChatMessage sent) {
    final list = _conversations[accountId];
    if (list == null) return;
    final updated = c.copyWith(
      lastActivity: sent.createdAt,
      lastMessagePreview: htmlToPlainText(sent.bodyHtml),
    );
    _conversations[accountId] = [
      updated,
      for (final x in list)
        if (x.key != c.key) x,
    ];
    _saveList(accountId);
  }

  @override
  Future<Either<Failure, List<ChatSearchHit>>> search(
    String accountId,
    String query,
  ) =>
      _guard(accountId, (ds) async {
        if (ds.searchesOnServer) {
          final hits = await ds.search(query);
          return _titled(accountId, hits);
        }
        return _scan(accountId, ds, query);
      });

  @override
  Future<Set<String>> colleagues(
      String accountId, Iterable<String> addresses) async {
    final ds = _ds(accountId);
    if (ds != null && SlackWorkspace.teamIdOf(accountId) != null) {
      // A Slack workspace is its own directory, unrelated to mail domains.
      try {
        return await ds.directoryMembers(
                addresses.map((a) => a.trim().toLowerCase()).toList()) ??
            const {};
      } catch (e) {
        debugPrint('[Chat] Slack directory lookup failed: $e');
        return const {};
      }
    }
    final account = _accounts.accountById(accountId);
    if (account == null) return const {};
    // The account's own domains — but a personal domain (gmail.com,
    // outlook.com) has no organisation behind it.
    final domains = {
      for (final a in account.allAddresses)
        if (!isConsumerEmailAddress(a) && a.contains('@')) a.split('@').last,
    };
    final wanted = addresses.map((a) => a.trim().toLowerCase()).toSet();
    final out = {
      for (final a in wanted)
        if (a.contains('@') && domains.contains(a.split('@').last)) a,
    };
    final rest = wanted.difference(out);
    if (rest.isEmpty) return out;
    try {
      out.addAll(await _contacts.directoryAddresses(
          accountId: accountId, addresses: rest));
    } catch (e) {
      // A cache that cannot answer leaves the domain rule standing alone.
      debugPrint('[Chat] directory lookup failed: $e');
    }
    return out;
  }

  /// Images and photos by `account|src`, as futures so a picture on screen
  /// in the pane and the window, or repeated down a history, is fetched
  /// once. Oldest dropped past [_imageCacheSize]; a miss stays a miss until
  /// it is dropped, so a 404 photo is not asked for on every poll.
  final _images = <String, Future<Uint8List?>>{};
  static const _imageCacheSize = 300;

  Future<Uint8List?> _cachedImage(
    String key,
    Future<Uint8List?> Function() fetch,
  ) {
    final hit = _images.remove(key);
    if (hit != null) return _images[key] = hit;
    final future = fetch();
    _images[key] = future;
    while (_images.length > _imageCacheSize) {
      _images.remove(_images.keys.first);
    }
    return future;
  }

  @override
  Future<Uint8List?> image(String accountId, String src) {
    final ds = _ds(accountId);
    if (ds == null) return Future.value();
    return _cachedImage('$accountId|img|$src', () => ds.image(src));
  }

  @override
  Future<Uint8List?> photo(String accountId, String userId) {
    final ds = _ds(accountId);
    if (ds == null || userId.isEmpty) return Future.value();
    return _cachedImage('$accountId|photo|$userId', () => ds.photo(userId));
  }

  @override
  Future<Set<String>> reachable(
    String accountId,
    List<({String email, String name})> people,
  ) async {
    final out = await colleagues(accountId, people.map((p) => p.email));
    // Slack's lookup already is "has a Slack account here"; someone it does
    // not know has no DM to find either.
    if (SlackWorkspace.teamIdOf(accountId) != null) return out;
    final outsiders = [
      for (final p in people)
        if (!out.contains(p.email.trim().toLowerCase())) p,
    ].take(_reachableLookups);
    final found = await Future.wait(outsiders.map((p) async {
      final chat = await findOneOnOne(accountId, p.email, name: p.name);
      return chat.match((_) => null, (c) => c == null ? null : p.email);
    }));
    return {
      ...out,
      for (final e in found)
        if (e != null) e.trim().toLowerCase(),
    };
  }

  /// How many outsiders on one email [reachable] looks up. On Graph each is a
  /// scan of the cached chat list; on Google a `findDirectMessage` call each.
  static const _reachableLookups = 8;

  /// Names each hit's conversation from the cached list.
  List<ChatSearchHit> _titled(String accountId, List<ChatSearchHit> hits) {
    final byKey = {
      for (final c in _conversations[accountId] ?? const <ChatConversation>[])
        c.key: c,
    };
    return [
      for (final h in hits)
        ChatSearchHit(
          chatId: h.chatId,
          teamId: h.teamId,
          channelId: h.channelId,
          message: _withTitle(h.message, byKey[h.conversationKey]?.title),
        ),
    ];
  }

  Future<List<ChatSearchHit>> _scan(
    String accountId,
    ChatRemoteDatasource ds,
    String query,
  ) async {
    final listed = _conversations[accountId] ?? await ds.listChats();
    final needle = query.trim().toLowerCase();
    final hits = <ChatSearchHit>[];
    bool matches(ChatMessage m) =>
        !m.isSystem &&
        !m.isDeleted &&
        (htmlToPlainText(m.bodyHtml).toLowerCase().contains(needle) ||
            (m.subject?.toLowerCase().contains(needle) ?? false));

    final targets = listed.take(_scanConversations).toList();
    // Four at a time: enough to be quick, few enough not to trip a server's
    // rate limit on an explicit search.
    for (var i = 0; i < targets.length; i += 4) {
      await Future.wait(targets.skip(i).take(4).map((c) async {
        String? next;
        for (var page = 0; page < _scanPages; page++) {
          final ChatMessagePage p;
          try {
            p = await ds.messages(c, cursor: next);
          } on ServerException {
            return;
          }
          for (final m in p.messages) {
            for (final candidate in [m, ...m.replies]) {
              if (!matches(candidate)) continue;
              hits.add(ChatSearchHit(
                message: _withTitle(candidate, c.title),
                chatId: c.isChannel ? null : c.id,
                teamId: c.teamId,
                channelId: c.isChannel ? c.id : null,
              ));
            }
          }
          next = p.nextLink;
          if (next == null) return;
        }
      }));
    }
    hits.sort((a, b) => b.message.createdAt.compareTo(a.message.createdAt));
    return hits;
  }

  static ChatMessage _withTitle(ChatMessage m, String? title) => ChatMessage(
        id: m.id,
        createdAt: m.createdAt,
        senderName: m.senderName,
        senderUserId: m.senderUserId,
        bodyHtml: m.bodyHtml,
        replyToId: m.replyToId,
        subject: m.subject,
        editedAt: m.editedAt,
        isDeleted: m.isDeleted,
        isSystem: m.isSystem,
        reactions: m.reactions,
        attachmentNames: m.attachmentNames,
        conversationTitle: title,
        threadId: m.threadId,
      );

  Future<Either<Failure, T>> _guard<T>(
    String accountId,
    Future<T> Function(ChatRemoteDatasource ds) run,
  ) async {
    final ds = _ds(accountId);
    if (ds == null) {
      return const Left(
          UnsupportedFailure(message: 'Chat is not available for this account'));
    }
    try {
      return Right(await run(ds));
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }
}
