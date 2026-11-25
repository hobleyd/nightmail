import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../core/settings/app_settings.dart';
import '../../../domain/entities/chat.dart';
import '../../../domain/repositories/chat_repository.dart';

class ChatListState extends Equatable {
  const ChatListState({
    this.accountId,
    this.access,
    this.conversations = const [],
    this.loading = false,
    this.error,
    this.unavailable = false,
    this.selectedKey,
    this.query = '',
    this.results,
    this.searching = false,
    this.sortByName = false,
  });

  final String? accountId;
  final ChatAccess? access;

  /// Newest activity first, chats and channels together.
  final List<ChatConversation> conversations;
  final bool loading;
  final String? error;
  final bool unavailable;
  final String? selectedKey;

  final String query;

  /// Null when no search has run; empty when one found nothing.
  final List<ChatSearchHit>? results;
  final bool searching;

  /// Each section A–Z rather than newest activity first.
  final bool sortByName;

  List<ChatConversation> _sorted(Iterable<ChatConversation> list) {
    final out = list.toList();
    if (sortByName) {
      out.sort((a, b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return out;
  }

  /// One-on-ones, group and meeting chats.
  List<ChatConversation> get chats => _sorted(
      conversations.where((c) => !c.isChannel && c.kind != ChatKind.space));

  /// Google Chat's named spaces.
  List<ChatConversation> get spaces =>
      _sorted(conversations.where((c) => c.kind == ChatKind.space));

  /// Each team's channels, teams ordered by their busiest channel and
  /// channels by activity — the order [conversations] already has — or both
  /// by name.
  List<(String teamName, List<ChatConversation> channels)> get teams {
    final byTeam = <String, List<ChatConversation>>{};
    final names = <String, String>{};
    for (final c in conversations.where((c) => c.isChannel)) {
      byTeam.putIfAbsent(c.teamId!, () => []).add(c);
      names[c.teamId!] = c.teamName ?? 'Team';
    }
    final out = [
      for (final e in byTeam.entries) (names[e.key]!, _sorted(e.value)),
    ];
    if (sortByName) {
      out.sort((a, b) => a.$1.toLowerCase().compareTo(b.$1.toLowerCase()));
    }
    return out;
  }

  ChatConversation? get selected => selectedKey == null
      ? null
      : conversations.where((c) => c.key == selectedKey).firstOrNull;

  ChatListState copyWith({
    String? accountId,
    ChatAccess? access,
    List<ChatConversation>? conversations,
    bool? loading,
    String? Function()? error,
    bool? unavailable,
    String? Function()? selectedKey,
    String? query,
    List<ChatSearchHit>? Function()? results,
    bool? searching,
    bool? sortByName,
  }) =>
      ChatListState(
        accountId: accountId ?? this.accountId,
        access: access ?? this.access,
        conversations: conversations ?? this.conversations,
        loading: loading ?? this.loading,
        error: error != null ? error() : this.error,
        unavailable: unavailable ?? this.unavailable,
        selectedKey: selectedKey != null ? selectedKey() : this.selectedKey,
        query: query ?? this.query,
        results: results != null ? results() : this.results,
        searching: searching ?? this.searching,
        sortByName: sortByName ?? this.sortByName,
      );

  @override
  List<Object?> get props => [
        accountId,
        access,
        conversations,
        loading,
        error,
        unavailable,
        selectedKey,
        query,
        results,
        searching,
        sortByName,
      ];
}

/// The chat window's left side: every chat and channel, newest activity
/// first, re-read every [pollInterval], and search across them.
class ChatListCubit extends Cubit<ChatListState> {
  ChatListCubit({
    required ChatRepository repository,
    AppSettings? settings,
  })  : _repo = repository,
        _settings = settings,
        super(const ChatListState()) {
    unawaited(_loadSort());
  }

  final ChatRepository _repo;

  /// Where the sort is remembered; none in tests.
  final AppSettings? _settings;

  Future<void> _loadSort() async {
    final byName = await _settings?.loadChatSortByName() ?? false;
    if (!isClosed && byName != state.sortByName) {
      emit(state.copyWith(sortByName: byName));
    }
  }

  /// Newest activity first, or A–Z; remembered for the next window.
  void setSortByName(bool byName) {
    if (byName == state.sortByName) return;
    emit(state.copyWith(sortByName: byName));
    unawaited(_settings?.saveChatSortByName(byName));
  }

  /// Which conversations have something unread, by key — laid over every
  /// listing, since only the unread poll's listing knows (Slack's and
  /// Google's full listings carry no read state).
  Set<String> _unread = const {};

  List<ChatConversation> _withUnread(List<ChatConversation> list) => [
        for (final c in list)
          c.unread == _unread.contains(c.key)
              ? c
              : c.copyWith(unread: _unread.contains(c.key)),
      ];

  Future<void> _checkUnread(int gen) async {
    final accountId = state.accountId;
    if (accountId == null) return;
    final unread = await _repo.unreadConversations(accountId);
    if (gen != _generation || isClosed) return;
    _unread = {for (final c in unread) c.key};
    emit(state.copyWith(conversations: _withUnread(state.conversations)));
  }

  static const pollInterval = Duration(seconds: 60);

  Timer? _poll;
  int _generation = 0;

  /// How many Slack conversations' activity one window load reads.
  /// `conversations.history` is Tier 3 (50+ a minute), and someone in 150
  /// channels would otherwise spend three minutes of it before the open
  /// conversation could poll; past these, a conversation sorts by name until
  /// it is opened or messaged.
  static const _slackActivityPerLoad = 40;

  /// Channels whose activity has been looked up this session.
  final _activityAsked = <String>{};

  Future<void> load(String accountId) async {
    final gen = ++_generation;
    _poll?.cancel();
    _activityAsked.clear();
    _unread = const {};
    emit(ChatListState(
        accountId: accountId, loading: true, sortByName: state.sortByName));
    // What this system last showed, while the server is asked.
    final cached = await _repo.cachedConversations(accountId);
    if (gen != _generation || isClosed) return;
    if (cached.isNotEmpty) {
      // A cached flag is as old as the cache: the poll below says again.
      emit(state.copyWith(conversations: _withUnread(cached)));
    }
    final access = await _repo.access(accountId);
    if (gen != _generation || isClosed) return;
    emit(state.copyWith(access: access));
    if (access == ChatAccess.unsupported || access == ChatAccess.needsConsent) {
      emit(state.copyWith(loading: false, conversations: const []));
      return;
    }
    await _list(gen, refresh: true);
    _poll = Timer.periodic(pollInterval, (_) => _list(gen, refresh: true));
  }

  Future<void> requestAccess({bool channels = false}) async {
    final accountId = state.accountId;
    if (accountId == null) return;
    final result = await _repo.requestAccess(accountId, channels: channels);
    if (isClosed) return;
    result.match(
      (f) => emit(state.copyWith(
        error: () => channels
            ? 'Channels need your administrator to approve NightMail '
                '(ChannelMessage.Read.All). Chats still work.\n${f.message}'
            : f.message,
      )),
      (_) => load(accountId),
    );
  }

  Future<void> refresh() => _list(_generation, refresh: true);

  Future<void> _list(int gen, {required bool refresh}) async {
    final accountId = state.accountId;
    if (accountId == null) return;
    final result = await _repo.conversations(accountId, refresh: refresh);
    if (gen != _generation || isClosed) return;
    result.match(
      (f) {
        final status = f is ServerFailure ? f.statusCode : null;
        emit(state.copyWith(
          loading: false,
          unavailable: status == 400 || status == 501,
          error: () => switch (f) {
            AuthFailure() => 'Sign in again to use chat (Settings > Accounts).',
            NetworkFailure() => 'Offline — chats will load when you reconnect.',
            _ => f.message,
          },
        ));
      },
      (list) {
        emit(state.copyWith(
            conversations: _withUnread(list),
            loading: false,
            error: () => null));
        unawaited(_checkUnread(gen));
        unawaited(_fillChannelActivity(gen, list));
      },
    );
  }

  /// Channel listings carry no activity (nor does any Slack listing), so
  /// each such conversation's newest post is read once, four at a time, and
  /// the list re-sorts as they land. On Slack that includes conversations
  /// whose activity only the cache knew — it may be days old — most recent
  /// first, up to [_slackActivityPerLoad].
  Future<void> _fillChannelActivity(
      int gen, List<ChatConversation> list) async {
    final accountId = state.accountId;
    if (accountId == null) return;
    final slack = ChatSource.isSlackId(accountId);
    final pending = slack
        // Direct and group messages first: they are the ones people answer.
        ? ([
            ...list.where((c) => c.kind != ChatKind.space),
            ...list.where((c) => c.kind == ChatKind.space),
          ]
            .where((c) => _activityAsked.add(c.key))
            .take(_slackActivityPerLoad)
            .toList())
        : list.where((c) => c.isChannel && _activityAsked.add(c.key)).toList();
    for (var i = 0; i < pending.length; i += 4) {
      await Future.wait(pending.skip(i).take(4).map(
            (c) => _repo.channelActivity(accountId, c),
          ));
      if (gen != _generation || isClosed) return;
      final again = await _repo.conversations(accountId);
      if (gen != _generation || isClosed) return;
      again.match(
          (_) {}, (l) => emit(state.copyWith(conversations: _withUnread(l))));
    }
  }

  /// Opening a conversation reads it: its row stops being bold at once
  /// rather than on the next poll.
  void select(String? key) {
    if (key != null && _unread.contains(key)) {
      _unread = {..._unread}..remove(key);
    }
    emit(state.copyWith(
      selectedKey: () => key,
      conversations: _withUnread(state.conversations),
    ));
  }

  Future<void> search(String query) async {
    final accountId = state.accountId;
    final q = query.trim();
    if (accountId == null) return;
    if (q.isEmpty) {
      clearSearch();
      return;
    }
    final gen = _generation;
    emit(state.copyWith(query: q, searching: true));
    final result = await _repo.search(accountId, q);
    if (gen != _generation || isClosed || state.query != q) return;
    result.match(
      (f) => emit(state.copyWith(
          searching: false, results: () => const [], error: () => f.message)),
      (hits) => emit(state.copyWith(searching: false, results: () => hits)),
    );
  }

  void clearSearch() => emit(
      state.copyWith(query: '', results: () => null, searching: false));

  @override
  Future<void> close() {
    _poll?.cancel();
    return super.close();
  }
}
