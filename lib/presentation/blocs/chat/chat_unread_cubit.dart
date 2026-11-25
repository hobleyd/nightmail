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
  });

  /// The active account's own chat first (when it has one), then each
  /// connected Slack workspace — [ChatRepository.sources].
  final List<ChatSource> sources;

  /// Unread chats by [ChatSource.id].
  final Map<String, int> unread;

  /// The unread chats themselves by [ChatSource.id] — what the pane's
  /// dropdown offers beside the people on the email.
  final Map<String, List<ChatConversation>> unreadChats;

  /// The system last picked from the menu, by id; may name one no longer
  /// offered (an account switch), see [chosen].
  final String? chosenId;

  /// What the Chat pane shows: the system last picked while it is still
  /// offered, otherwise the first — the account's own chat when it has one.
  ChatSource? get chosen =>
      sources.where((s) => s.id == chosenId).firstOrNull ?? sources.firstOrNull;

  int get total => unread.values.fold(0, (a, b) => a + b);

  int unreadIn(String sourceId) => unread[sourceId] ?? 0;

  /// More than one system: the button asks which, as a menu.
  bool get hasChoice => sources.length > 1;

  @override
  List<Object?> get props => [sources, unread, chosenId, unreadChats];
}

/// The chat systems behind the Chat button and how many of each's chats
/// have something the user has not read — the dot, and the menu's per-system
/// dots.
///
/// This polls: one page of recent chats per system every [pollInterval]
/// ([ChatRepository.unreadCount]). A chat read in this window clears at once
/// ([ChatRepository.reads]); one read in the chat window — its own isolate —
/// or in Teams or Slack clears on the next poll. A NightMail Server account
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

  Timer? _timer;
  StreamSubscription<String>? _reads;
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
    ));
    final chats = await Future.wait(sources.map((s) => s.needsReconnect
        ? Future.value(const <ChatConversation>[])
        : _repository.unreadConversations(s.id)));
    if (gen != _generation || isClosed) return;
    emit(ChatUnreadState(
      sources: sources,
      chosenId: state.chosenId,
      unread: {
        for (var i = 0; i < sources.length; i++)
          sources[i].id: chats[i].where((c) => _counts(sources[i], c)).length,
      },
      unreadChats: {
        for (var i = 0; i < sources.length; i++) sources[i].id: chats[i],
      },
    ));
  }

  /// Whether [chat] counts towards the dot. A Slack channel is bolded in
  /// the window and offered in the pane, but — as on Slack's own badge —
  /// a channel message is not something waiting on the user.
  static bool _counts(ChatSource source, ChatConversation chat) =>
      !(source.isSlack && chat.kind == ChatKind.space);

  /// Points the Chat pane at [sourceId] (from the button's menu).
  void choose(String sourceId) {
    _switched = sourceId != state.chosen?.id;
    emit(ChatUnreadState(
        sources: state.sources,
        unread: state.unread,
        unreadChats: state.unreadChats,
        chosenId: sourceId));
  }

  bool _switched = false;

  /// Whether the click being handled picked a different system from the one
  /// the pane was on — which switches an open pane rather than closing it.
  /// Read once: false again after, and always false without a menu, so the
  /// button is the plain toggle it always was.
  bool takeSwitched() {
    final switched = _switched;
    _switched = false;
    return switched;
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    _reads?.cancel();
    _sourcesChanged?.cancel();
    _changes?.cancel();
    return super.close();
  }
}
