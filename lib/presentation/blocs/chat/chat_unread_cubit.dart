import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/chat.dart';
import '../../../domain/repositories/chat_repository.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import '../../../infrastructure/sync/change_stream_service.dart';

/// What the Chat button shows: which chat systems it opens and how many
/// unread chats each has.
class ChatUnreadState extends Equatable {
  const ChatUnreadState({
    this.sources = const [],
    this.unread = const {},
    this.chosenId,
    this.unreadChats = const {},
    this.recentlyRead = const {},
  });

  /// The active account's own chat first (when it has one), then each
  /// connected Slack workspace — [ChatRepository.sources].
  final List<ChatSource> sources;

  /// Unread chats by [ChatSource.id].
  final Map<String, int> unread;

  /// The unread chats themselves by [ChatSource.id] — what the pane's
  /// dropdown offers beside the people on the email.
  final Map<String, List<ChatConversation>> unreadChats;

  /// Chats read here in the last [ChatUnreadCubit.readLinger], by
  /// [ChatSource.id], newest read first — kept in the pane's unread list
  /// (below the unread ones, not bold) so a follow-up is a click away.
  /// Not counted in [unread].
  final Map<String, List<ChatConversation>> recentlyRead;

  /// The system last picked in the pane's dropdown, by id; may name one no longer
  /// offered (an account switch), see [chosen].
  final String? chosenId;

  /// What the Chat pane shows: the system last picked while it is still
  /// offered, otherwise the first — the account's own chat when it has one.
  ChatSource? get chosen =>
      sources.where((s) => s.id == chosenId).firstOrNull ?? sources.firstOrNull;

  int get total => unread.values.fold(0, (a, b) => a + b);

  int unreadIn(String sourceId) => unread[sourceId] ?? 0;

  /// More than one system: the pane's header is a dropdown of them, and the
  /// button's tooltip names which has the unread chats.
  bool get hasChoice => sources.length > 1;

  @override
  List<Object?> get props =>
      [sources, unread, chosenId, unreadChats, recentlyRead];
}

/// The chat systems behind the Chat button and how many of each's chats
/// have something the user has not read — the button's dot, and the pane's
/// unread list and per-system dots.
///
/// This polls: one page of recent chats per system every [pollInterval]
/// ([ChatRepository.unreadCount]). A chat read in this window clears at once
/// ([ChatRepository.readKeys], before the server answers; [ChatRepository.reads]
/// re-polls once it has), and so does one read in the chat window — its
/// own isolate — passed here by `ChatReadRelay`; one read in Teams or Slack
/// itself clears on the next poll. A NightMail Server account
/// also refreshes when its change stream says `chat` (nightware ADR 0007 D5):
/// a new message or a read elsewhere shows within seconds, not a minute.
class ChatUnreadCubit extends Cubit<ChatUnreadState> {
  ChatUnreadCubit({
    required this._accountManager,
    required this._repository,
    this._changeSignals,
  }) : super(const ChatUnreadState());

  final AccountManager _accountManager;
  final ChatRepository _repository;
  final Stream<ChangeSignal>? _changeSignals;

  static const pollInterval = Duration(seconds: 60);

  /// How long a chat read here stays in the pane's list
  /// ([ChatUnreadState.recentlyRead]) after it drops out of the unread ones.
  static const readLinger = Duration(seconds: 45);

  /// One per lingering chat, by `sourceId|key`.
  final Map<String, Timer> _lingers = {};

  Timer? _timer;
  StreamSubscription<String>? _reads;
  StreamSubscription<void>? _readKeys;
  StreamSubscription<void>? _sourcesChanged;
  StreamSubscription<ChangeSignal>? _changes;

  /// Bumped per [refresh] so a slow answer for the account being left never
  /// lands after the arriving one's.
  int _generation = 0;

  /// Safe to call repeatedly — HomePage calls it on every build.
  void start() {
    _reads ??= _repository.reads.listen((id) {
      if (state.sources.any((s) => s.id == id)) unawaited(refresh());
    });
    // A read is dropped here as it is announced — before the server has the
    // mark when it is this window's (`reads` re-polls after), and without a
    // re-poll when it is the chat window's: a refresh asks every system, and
    // clicking down a row of Slack channels would spend that many polls of
    // Slack's quota.
    _readKeys ??= _repository.readKeys
        .listen((r) => _dropRead(r.accountId, r.key));
    _sourcesChanged ??=
        _repository.sourcesChanged.listen((_) => unawaited(refresh()));
    // `ready` names `chat` too, so a (re)connected stream refreshes once —
    // nothing in between was signalled. A server without the area never
    // names it, and the timer carries on as before.
    _changes ??= _changeSignals?.listen((signal) {
      if (signal.concerns('chat') &&
          state.sources.any((s) => s.id == signal.accountId)) {
        unawaited(refresh());
      }
    });
    if (_timer != null) return;
    _timer = Timer.periodic(pollInterval, (_) => refresh());
    unawaited(refresh());
  }

  Future<void> refresh() async {
    final gen = ++_generation;
    final sources =
        await _repository.sources(_accountManager.activeAccount?.id);
    if (gen != _generation || isClosed) return;
    // The menu appears with its systems at once; the counts follow.
    emit(ChatUnreadState(
      sources: sources,
      chosenId: state.chosenId,
      unread: {for (final s in sources) s.id: ?state.unread[s.id]},
      unreadChats: {
        for (final s in sources) s.id: ?state.unreadChats[s.id],
      },
      recentlyRead: state.recentlyRead,
    ));
    final chats = await Future.wait(sources.map((s) => s.needsReconnect
        ? Future.value(const <ChatConversation>[])
        : _repository.unreadConversations(s.id)));
    if (gen != _generation || isClosed) return;
    final unreadChats = {
      for (var i = 0; i < sources.length; i++) sources[i].id: chats[i],
    };
    emit(ChatUnreadState(
      sources: sources,
      chosenId: state.chosenId,
      unread: {
        for (var i = 0; i < sources.length; i++)
          sources[i].id: chats[i].length,
      },
      unreadChats: unreadChats,
      // Unread again (someone followed up): it is back in the unread ones.
      recentlyRead: {
        for (final MapEntry(key: id, value: read) in state.recentlyRead.entries)
          id: [
            for (final r in read)
              if (!(unreadChats[id] ?? const []).any((u) => u.key == r.key))
                r,
          ],
      },
    ));
  }

  /// Points the Chat pane at [sourceId] (from the pane's dropdown).
  void choose(String sourceId) {
    emit(ChatUnreadState(
        sources: state.sources,
        unread: state.unread,
        unreadChats: state.unreadChats,
        recentlyRead: state.recentlyRead,
        chosenId: sourceId));
  }

  void _dropRead(String sourceId, String key) {
    final chats = state.unreadChats[sourceId];
    if (chats == null || !chats.any((c) => c.key == key)) return;
    final read = chats.firstWhere((c) => c.key == key);
    final left = [for (final c in chats) if (c.key != key) c];
    final lingering = state.recentlyRead[sourceId] ?? const [];
    emit(ChatUnreadState(
      sources: state.sources,
      chosenId: state.chosenId,
      unread: {...state.unread, sourceId: left.length},
      unreadChats: {...state.unreadChats, sourceId: left},
      recentlyRead: {
        ...state.recentlyRead,
        sourceId: [
          read.copyWith(unread: false),
          for (final c in lingering) if (c.key != key) c,
        ],
      },
    ));
    final id = '$sourceId|$key';
    _lingers[id]?.cancel();
    _lingers[id] = Timer(readLinger, () {
      _lingers.remove(id);
      if (isClosed) return;
      final lingering = state.recentlyRead[sourceId];
      if (lingering == null || !lingering.any((c) => c.key == key)) return;
      emit(ChatUnreadState(
        sources: state.sources,
        chosenId: state.chosenId,
        unread: state.unread,
        unreadChats: state.unreadChats,
        recentlyRead: {
          ...state.recentlyRead,
          sourceId: [for (final c in lingering) if (c.key != key) c],
        },
      ));
    });
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    _reads?.cancel();
    _readKeys?.cancel();
    _sourcesChanged?.cancel();
    _changes?.cancel();
    for (final t in _lingers.values) {
      t.cancel();
    }
    return super.close();
  }
}
