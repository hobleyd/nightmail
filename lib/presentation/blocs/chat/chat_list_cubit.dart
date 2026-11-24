import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
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

  /// One-on-ones, group and meeting chats.
  List<ChatConversation> get chats => conversations
      .where((c) => !c.isChannel && c.kind != ChatKind.space)
      .toList();

  /// Google Chat's named spaces.
  List<ChatConversation> get spaces =>
      conversations.where((c) => c.kind == ChatKind.space).toList();

  /// Each team's channels, teams ordered by their busiest channel and
  /// channels by activity — the order [conversations] already has.
  List<(String teamName, List<ChatConversation> channels)> get teams {
    final byTeam = <String, List<ChatConversation>>{};
    final names = <String, String>{};
    for (final c in conversations.where((c) => c.isChannel)) {
      byTeam.putIfAbsent(c.teamId!, () => []).add(c);
      names[c.teamId!] = c.teamName ?? 'Team';
    }
    return [
      for (final e in byTeam.entries) (names[e.key]!, e.value),
    ];
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
      ];
}

/// The chat window's left side: every chat and channel, newest activity
/// first, re-read every [pollInterval], and search across them.
class ChatListCubit extends Cubit<ChatListState> {
  ChatListCubit({required ChatRepository repository})
      : _repo = repository,
        super(const ChatListState());

  final ChatRepository _repo;

  static const pollInterval = Duration(seconds: 60);

  Timer? _poll;
  int _generation = 0;

  /// Channels whose activity has been looked up this session.
  final _activityAsked = <String>{};

  Future<void> load(String accountId) async {
    final gen = ++_generation;
    _poll?.cancel();
    _activityAsked.clear();
    emit(ChatListState(accountId: accountId, loading: true));
    final access = await _repo.access(accountId);
    if (gen != _generation || isClosed) return;
    emit(state.copyWith(access: access));
    if (access == ChatAccess.unsupported || access == ChatAccess.needsConsent) {
      emit(state.copyWith(loading: false));
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
            conversations: list, loading: false, error: () => null));
        unawaited(_fillChannelActivity(gen, list));
      },
    );
  }

  /// Channel listings carry no activity, so each channel's newest post is
  /// read once, four at a time, and the list re-sorts as they land.
  Future<void> _fillChannelActivity(
      int gen, List<ChatConversation> list) async {
    final accountId = state.accountId;
    if (accountId == null) return;
    final pending = list
        .where((c) => c.isChannel && _activityAsked.add(c.key))
        .toList();
    for (var i = 0; i < pending.length; i += 4) {
      await Future.wait(pending.skip(i).take(4).map(
            (c) => _repo.channelActivity(accountId, c),
          ));
      if (gen != _generation || isClosed) return;
      final again = await _repo.conversations(accountId);
      if (gen != _generation || isClosed) return;
      again.match((_) {}, (l) => emit(state.copyWith(conversations: l)));
    }
  }

  void select(String? key) => emit(state.copyWith(selectedKey: () => key));

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
