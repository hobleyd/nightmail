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
import '../datasources/remote/chat_remote_datasource.dart';
import '../datasources/remote/slack_chat_datasource.dart';

class ChatRepositoryImpl implements ChatRepository {
  ChatRepositoryImpl({
    required AccountManager accountManager,
    required ContactCacheRepository contacts,
    required this._slack,
  })  : _accounts = accountManager,
        _contacts = contacts;

  final AccountManager _accounts;
  final ContactCacheRepository _contacts;
  final SlackWorkspaces _slack;

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
    _conversations.remove(sourceId);
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
        // whatever has been learned of either is kept across refreshes.
        final merged = [
          for (final c in [...chats, ...channels])
            c.lastActivity == null
                ? _channelActivity['$accountId|${c.key}'] ?? c
                : c,
        ]..sort(_byActivity);
        _conversations[accountId] = merged;
        _listedAt[accountId] = DateTime.now();
        return merged;
      });

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
            for (final c in list) c.key == updated.key ? updated : c,
          ]..sort(_byActivity);
        }
        return updated;
      });

  @override
  Future<int> unreadCount(String accountId) async {
    final access = await this.access(accountId);
    if (access != ChatAccess.chatsOnly && access != ChatAccess.full) return 0;
    final recent = await _guard(accountId, (ds) => ds.listRecentChats());
    return recent.match((f) {
      debugPrint('[Chat] unread count failed: ${f.message}');
      return 0;
    }, (chats) => chats.where((c) {
      if (!c.unread) return false;
      // Microsoft's read state can trail a mark by a moment; a chat marked
      // here stays read until something newer arrives in it.
      final marked = _markedAt['$accountId|${c.key}'];
      final at = c.lastActivity;
      return marked == null || (at != null && at.isAfter(marked));
    }).length);
  }

  /// When [markRead] last ran per `account|conversation`.
  final _markedAt = <String, DateTime>{};

  final _reads = StreamController<String>.broadcast();

  @override
  Stream<String> get reads => _reads.stream;

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
    final list = _conversations[accountId];
    if (list != null) {
      _conversations[accountId] = [
        for (final c in list)
          c.key == conversation.key ? c.copyWith(unread: false) : c,
      ];
    }
    _reads.add(accountId);
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
    final listed = await conversations(accountId, refresh: stale);
    return listed.map((all) {
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
    });
  }

  @override
  Future<Either<Failure, ChatMessagePage>> messages(
    String accountId,
    ChatConversation conversation, {
    String? nextLink,
  }) =>
      _guard(accountId,
          (ds) => ds.messages(conversation, cursor: nextLink));

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
  }) =>
      _guard(accountId, (ds) async {
        final sent = await ds.send(conversation, text, replyTo: replyTo);
        _touch(accountId, conversation, sent);
        return sent;
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
