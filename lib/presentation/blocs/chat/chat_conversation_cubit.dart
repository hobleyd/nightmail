import 'dart:async';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/chat.dart';
import '../../../domain/repositories/chat_repository.dart';
import 'chat_drafts.dart';

/// Someone the pane will chat with once the first message is sent — there is
/// no one-on-one with them yet, and opening the pane must not make one (on a
/// NightMail Server the other person sees a new Talk room at once).
class ChatPerson extends Equatable {
  const ChatPerson({required this.email, required this.name});

  final String email;
  final String name;

  String get label => name.isNotEmpty ? name : email;

  @override
  List<Object?> get props => [email, name];
}

class ChatConversationState extends Equatable {
  const ChatConversationState({
    this.accountId,
    this.access,
    this.conversation,
    this.person,
    this.messages = const [],
    this.nextLink,
    this.loading = false,
    this.loadingOlder = false,
    this.sending = false,
    this.error,
    this.unavailable = false,
    this.threadPostId,
    this.threadReplies = const [],
    this.threadLoading = false,
    this.ownUserId,
    this.editing,
    this.editingInThread = false,
  });

  final String? accountId;
  final ChatAccess? access;

  /// The open chat or channel; null while [person] has none yet.
  final ChatConversation? conversation;

  /// Who the pane is pointed at, when opened by person rather than chat.
  final ChatPerson? person;

  /// Newest first. In a channel, the posts.
  final List<ChatMessage> messages;
  final String? nextLink;
  final bool loading;
  final bool loadingOlder;
  final bool sending;
  final String? error;

  /// The server does not offer chat at all (a NightMail Server without
  /// Talk, or one older than nightware phase 23).
  final bool unavailable;

  /// A channel post whose replies are open beside or over the posts.
  final String? threadPostId;

  /// Oldest first.
  final List<ChatMessage> threadReplies;
  final bool threadLoading;

  /// The user's own [ChatMessage.senderUserId], once known — their messages
  /// wear one colour in every conversation.
  final String? ownUserId;

  /// The user's own message a composer is editing, or null when both send.
  final ChatMessage? editing;

  /// Whether [editing] belongs to the open thread's composer — the pencil
  /// was pressed in the thread — rather than the conversation's. Only that
  /// composer saves it; the other one goes on sending.
  final bool editingInThread;

  ChatMessage? get threadPost => threadPostId == null
      ? null
      : messages.where((m) => m.id == threadPostId).firstOrNull;

  ChatConversationState copyWith({
    String? accountId,
    ChatAccess? access,
    ChatConversation? Function()? conversation,
    ChatPerson? Function()? person,
    List<ChatMessage>? messages,
    String? Function()? nextLink,
    bool? loading,
    bool? loadingOlder,
    bool? sending,
    String? Function()? error,
    bool? unavailable,
    String? Function()? threadPostId,
    List<ChatMessage>? threadReplies,
    bool? threadLoading,
    String? ownUserId,
    ChatMessage? Function()? editing,
    bool? editingInThread,
  }) =>
      ChatConversationState(
        accountId: accountId ?? this.accountId,
        access: access ?? this.access,
        conversation: conversation != null ? conversation() : this.conversation,
        person: person != null ? person() : this.person,
        messages: messages ?? this.messages,
        nextLink: nextLink != null ? nextLink() : this.nextLink,
        loading: loading ?? this.loading,
        loadingOlder: loadingOlder ?? this.loadingOlder,
        sending: sending ?? this.sending,
        error: error != null ? error() : this.error,
        unavailable: unavailable ?? this.unavailable,
        threadPostId: threadPostId != null ? threadPostId() : this.threadPostId,
        threadReplies: threadReplies ?? this.threadReplies,
        threadLoading: threadLoading ?? this.threadLoading,
        ownUserId: ownUserId ?? this.ownUserId,
        editing: editing != null ? editing() : this.editing,
        editingInThread: editingInThread ?? this.editingInThread,
      );

  @override
  List<Object?> get props => [
        accountId,
        access,
        conversation,
        person,
        messages,
        nextLink,
        loading,
        loadingOlder,
        sending,
        error,
        unavailable,
        threadPostId,
        threadReplies,
        threadLoading,
        ownUserId,
        editing,
        editingInThread,
      ];
}

/// One open conversation: its history, older pages, sending, a channel
/// post's thread, and polling for what arrives while it is on screen.
///
/// Nothing pushes chat to NightMail — Graph's change notifications need a
/// webhook and Nightware leaves chat notifications out (ADR 0009 D1) — so the
/// open conversation is re-read every [pollInterval]. Every result is checked
/// against [_generation]: a reply for a conversation (or account) the user
/// has since moved off is dropped, never shown in the new one.
///
/// A chat on screen is read: when its newest message is someone else's, the
/// server is told ([ChatRepository.markRead]) — once per newest message, and
/// only while the app is in the foreground, or a message that lands while
/// the user is away would be marked read in Teams too. One skipped while
/// away is marked when the app comes back, and every poll tries again: the
/// polls after it are often empty deltas, and the chat stayed lit (the
/// dropdown's dot with it) until it was opened again.
class ChatConversationCubit extends Cubit<ChatConversationState> {
  ChatConversationCubit({
    required ChatRepository repository,
    bool Function()? isForeground,
    ChatDrafts? drafts,
  })  : _repo = repository,
        _isForeground = isForeground ?? _appInForeground,
        drafts = drafts ?? ChatDrafts(),
        super(const ChatConversationState()) {
    if (isForeground == null) {
      _lifecycle = AppLifecycleListener(onResume: _markReadIfSeen);
    }
  }

  AppLifecycleListener? _lifecycle;

  final ChatRepository _repo;

  /// What the composers had typed and not sent, by conversation — shared
  /// by every pane in this window, and kept after this cubit closes.
  final ChatDrafts drafts;
  final bool Function() _isForeground;

  /// Null is foreground: every engine, a chat sub-window's too, hears the
  /// app's resign/become-active (macOS registers each with
  /// `FlutterAppDelegate`), so the state is only null before the first
  /// change — and a window is only opened while the user is in the app.
  static bool _appInForeground() {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  /// The newest message each conversation was marked read up to, by key.
  final _markedUpTo = <String, String>{};

  /// The open conversation was listed unread ([ChatConversation.unread])
  /// and has not been marked since it opened: it is marked whatever its
  /// newest message is. A Slack channel lit by a thread reply can have the
  /// user's own post, or one marked earlier, as its newest, and stayed lit.
  bool _openedUnread = false;

  static const pollInterval = Duration(seconds: 10);

  /// Where a delta asks from wholly misses edits, deletions and reactions
  /// (Slack, Google), every this-many polls reads the full newest page.
  static const fullPageEvery = 6;

  Timer? _poll;
  int _generation = 0;

  /// The newest server timestamp the open conversation is known up to —
  /// what the next poll asks the changes since. Null before the first page.
  DateTime? _watermark;

  /// Whether the last delta also brought edits and reactions (Graph), so
  /// polls need no full page.
  bool _deltaComplete = false;
  int _polls = 0;

  /// Checks what [accountId] can do, before anything is opened.
  Future<ChatAccess> checkAccess(String accountId) async {
    final gen = ++_generation;
    _poll?.cancel();
    final access = await _repo.access(accountId);
    if (gen == _generation && !isClosed) {
      emit(ChatConversationState(accountId: accountId, access: access));
    }
    return access;
  }

  /// Asks for consent, then reports the access the account ends up with.
  Future<ChatAccess?> requestAccess(String accountId,
      {bool channels = false}) async {
    final result = await _repo.requestAccess(accountId, channels: channels);
    if (isClosed) return null;
    return result.match(
      (f) {
        emit(state.copyWith(error: () => _messageOf(f)));
        return null;
      },
      (access) {
        emit(state.copyWith(access: access, error: () => null));
        return access;
      },
    );
  }

  /// Opens the one-on-one with [person], or readies one to be started.
  Future<void> openPerson(String accountId, ChatPerson person) async {
    final gen = ++_generation;
    _poll?.cancel();
    _resetPolls();
    emit(ChatConversationState(
      accountId: accountId,
      access: state.accountId == accountId ? state.access : null,
      ownUserId: state.accountId == accountId ? state.ownUserId : null,
      person: person,
      loading: true,
    ));
    final found =
        await _repo.findOneOnOne(accountId, person.email, name: person.name);
    if (gen != _generation || isClosed) return;
    found.match(
      (f) => _fail(f),
      (chat) {
        if (chat == null) {
          emit(state.copyWith(loading: false));
        } else {
          _load(accountId, chat, gen);
        }
      },
    );
  }

  Future<void> open(String accountId, ChatConversation conversation) async {
    final gen = ++_generation;
    _poll?.cancel();
    emit(ChatConversationState(
      accountId: accountId,
      access: state.accountId == accountId ? state.access : null,
      ownUserId: state.accountId == accountId ? state.ownUserId : null,
      conversation: conversation,
      loading: true,
    ));
    await _load(accountId, conversation, gen);
  }

  void clear() {
    ++_generation;
    _poll?.cancel();
    _resetPolls();
    emit(ChatConversationState(
        accountId: state.accountId,
        access: state.access,
        ownUserId: state.ownUserId));
  }

  /// Paints what the cache on disk last held for [conversation], then reads
  /// the newest page and joins the two where they meet.
  Future<void> _load(
      String accountId, ChatConversation conversation, int gen) async {
    emit(state.copyWith(conversation: () => conversation, loading: true));
    _resetPolls();
    _openedUnread = conversation.unread;
    final own = _learnOwnId(accountId, conversation, gen);
    final cached = await _repo.cachedMessages(accountId, conversation);
    if (gen != _generation || isClosed) return;
    if (cached.isNotEmpty) {
      emit(state.copyWith(messages: cached, loading: false));
    }
    final page = await _repo.messages(accountId, conversation);
    if (gen != _generation || isClosed) return;
    page.match(
      (f) {
        if (cached.isEmpty || f is! NetworkFailure) return _fail(f);
        // Offline: what was cached stands, and the polls catch up later.
        emit(state.copyWith(error: () => _messageOf(f)));
        _startPolling(gen);
      },
      (p) {
        final messages = joinCached(p, cached);
        emit(state.copyWith(
          messages: messages,
          nextLink: () => p.nextLink,
          loading: false,
          error: () => null,
        ));
        _watermark = newestStamp(p.messages);
        unawaited(_repo.cacheMessages(accountId, conversation, messages));
        _startPolling(gen);
      },
    );
    await own;
    _markReadIfSeen();
  }

  /// The newest [page] with the [cached] messages older than it — only where
  /// the two meet. A page that is the whole history, or that ends after the
  /// newest cached message (more arrived than one page holds), stands alone:
  /// anything else would show a gap as if nothing were missing.
  @visibleForTesting
  static List<ChatMessage> joinCached(
      ChatMessagePage page, List<ChatMessage> cached) {
    final fresh = page.messages;
    if (fresh.isEmpty || cached.isEmpty || page.nextLink == null) return fresh;
    final oldest = fresh.last.createdAt;
    if (oldest.isAfter(cached.first.createdAt)) return fresh;
    final ids = {for (final m in fresh) m.id};
    return [
      ...fresh,
      for (final m in cached)
        if (!ids.contains(m.id) && m.createdAt.isBefore(oldest)) m,
    ];
  }

  /// The newest server time [messages] carry: a post or its edit.
  @visibleForTesting
  static DateTime? newestStamp(Iterable<ChatMessage> messages) {
    DateTime? newest;
    for (final m in messages) {
      final t = m.editedAt != null && m.editedAt!.isAfter(m.createdAt)
          ? m.editedAt!
          : m.createdAt;
      if (newest == null || t.isAfter(newest)) newest = t;
    }
    return newest;
  }

  void _cache() {
    final accountId = state.accountId;
    final conversation = state.conversation;
    if (accountId == null || conversation == null) return;
    unawaited(_repo.cacheMessages(accountId, conversation, state.messages));
  }

  /// Google names the user per space, so this asks with the conversation;
  /// Graph answers from a cache after the first time.
  Future<void> _learnOwnId(
      String accountId, ChatConversation conversation, int gen) async {
    if (state.ownUserId != null) return;
    final id = await _repo.ownUserId(accountId, conversation: conversation);
    if (id != null && gen == _generation && !isClosed) {
      emit(state.copyWith(ownUserId: id));
    }
  }

  void _markReadIfSeen() {
    final accountId = state.accountId;
    final conversation = state.conversation;
    final own = state.ownUserId;
    if (accountId == null ||
        conversation == null ||
        conversation.isChannel ||
        own == null ||
        isClosed) {
      return;
    }
    // The newest thing on screen: the newest message, or a reply in the
    // open thread when that is newer — a Slack reply lights its channel.
    ChatMessage? newest = state.messages.where((m) => !m.isSystem).firstOrNull;
    for (final r in state.threadReplies) {
      if (!r.isSystem &&
          (newest == null || r.createdAt.isAfter(newest.createdAt))) {
        newest = r;
      }
    }
    if (newest == null) return;
    final opened = _openedUnread;
    if (!opened && _markedUpTo[conversation.key] == newest.id) return;
    if (!opened && newest.senderUserId == own) {
      _markedUpTo[conversation.key] = newest.id;
      return;
    }
    if (!_isForeground()) return;
    _openedUnread = false;
    _markedUpTo[conversation.key] = newest.id;
    unawaited(_repo.markRead(accountId, conversation));
  }

  /// Forgets the open conversation's place: a new one starts from its own
  /// first page.
  void _resetPolls() {
    _watermark = null;
    _deltaComplete = false;
    _polls = 0;
  }

  void _startPolling(int gen) {
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) => _refresh(gen));
  }

  /// Asks what changed since [_watermark] and merges it over what is shown.
  /// Where the provider cannot say — or its deltas miss edits and reactions,
  /// every [fullPageEvery] polls — re-reads the newest page instead: new
  /// messages arrive, edits, deletions and reactions update, older pages
  /// stay.
  Future<void> _refresh(int gen) async {
    final accountId = state.accountId;
    final conversation = state.conversation;
    if (accountId == null || conversation == null) return;
    _polls++;
    final since = _watermark;
    if (since != null && (_deltaComplete || _polls % fullPageEvery != 0)) {
      final delta = await _repo.messagesSince(accountId, conversation,
          since.subtract(const Duration(seconds: 1)));
      if (gen != _generation || isClosed) return;
      final applied = delta.match((_) => true, (d) {
        if (d == null) return false;
        _deltaComplete = d.complete;
        _applyDelta(d);
        return true;
      });
      if (applied) {
        _markReadIfSeen();
        if (state.threadPostId != null) unawaited(_reloadThread(gen));
        return;
      }
    }
    final page = await _repo.messages(accountId, conversation);
    if (gen != _generation || isClosed) return;
    page.match((_) => _markReadIfSeen(), (p) {
      final stamp = newestStamp(p.messages);
      if (stamp != null && (_watermark == null || stamp.isAfter(_watermark!))) {
        _watermark = stamp;
      }
      final fresh = {for (final m in p.messages) m.id: m};
      final oldest = p.messages.isEmpty ? null : p.messages.last.createdAt;
      final merged = [
        ...p.messages,
        for (final m in state.messages)
          if (!fresh.containsKey(m.id) &&
              (oldest == null || m.createdAt.isBefore(oldest)))
            m,
      ];
      if (merged.length != state.messages.length ||
          !_sameList(merged, state.messages)) {
        emit(state.copyWith(messages: merged));
        _cache();
      }
      _markReadIfSeen();
    });
    if (state.threadPostId != null) unawaited(_reloadThread(gen));
  }

  /// One poll, now — what the timer does every [pollInterval].
  @visibleForTesting
  Future<void> pollNow() => _refresh(_generation);

  /// Each message in [d] replaces the one with its id, or arrives. Graph's
  /// delta also reports a reaction to a message weeks back: one older than
  /// anything shown is not loaded yet, and inserting it would sit it below
  /// the history with a gap above — "load older" reaches it in its place.
  void _applyDelta(ChatMessageDelta d) {
    final w = d.watermark;
    if (w != null && (_watermark == null || w.isAfter(_watermark!))) {
      _watermark = w;
    }
    if (d.messages.isEmpty) return;
    final byId = {for (final m in state.messages) m.id: m};
    final oldestShown = state.messages.lastOrNull?.createdAt;
    var changed = false;
    for (final m in d.messages) {
      final shown = byId.containsKey(m.id);
      if (!shown &&
          oldestShown != null &&
          m.createdAt.isBefore(oldestShown)) {
        continue;
      }
      if (byId[m.id] != m) {
        byId[m.id] = m;
        changed = true;
      }
    }
    if (changed) {
      emit(state.copyWith(
          messages: byId.values.toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt))));
      _cache();
    }
    _markReadIfSeen();
  }

  static bool _sameList(List<ChatMessage> a, List<ChatMessage> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> loadOlder() async {
    final accountId = state.accountId;
    final conversation = state.conversation;
    final next = state.nextLink;
    if (accountId == null ||
        conversation == null ||
        next == null ||
        state.loadingOlder) {
      return;
    }
    final gen = _generation;
    emit(state.copyWith(loadingOlder: true));
    final page = await _repo.messages(accountId, conversation, nextLink: next);
    if (gen != _generation || isClosed) return;
    page.match(
      (f) => emit(state.copyWith(loadingOlder: false, error: () => _messageOf(f))),
      (p) {
        // Messages the cache supplied below the fresh page come again here:
        // the server's copy wins — edits, reactions, a workspace emoji the
        // cached rendering predates — and new ones go on the end.
        final fresh = {for (final m in p.messages) m.id: m};
        final shown = {for (final m in state.messages) m.id};
        emit(state.copyWith(
          messages: [
            for (final m in state.messages) fresh[m.id] ?? m,
            ...p.messages.where((m) => !shown.contains(m.id)),
          ],
          nextLink: () => p.nextLink,
          loadingOlder: false,
        ));
        if (p.messages.any((m) => shown.contains(m.id))) _cache();
      },
    );
  }

  /// Whether [m] is the user's own and its provider lets it be edited here.
  bool canEdit(ChatMessage m) {
    final accountId = state.accountId;
    final conversation = state.conversation;
    final own = state.ownUserId;
    return accountId != null &&
        conversation != null &&
        own != null &&
        m.senderUserId == own &&
        !m.isDeleted &&
        !m.isSystem &&
        m.editableText != null &&
        _repo.canEdit(accountId, conversation);
  }

  /// Whether the open conversation can be renamed here.
  bool get canRename {
    final accountId = state.accountId;
    final conversation = state.conversation;
    return accountId != null &&
        conversation != null &&
        _repo.canRename(accountId, conversation);
  }

  /// Whether a pasted picture can be sent in the open conversation. Not
  /// before it exists: a one-on-one is started with text.
  bool get canSendImage {
    final accountId = state.accountId;
    final conversation = state.conversation;
    return accountId != null &&
        conversation != null &&
        _repo.canSendImage(accountId, conversation);
  }

  /// Renames the open conversation to [title]. Null when it was renamed
  /// ([ChatConversationState.conversation] then carries the new title),
  /// otherwise why not, for the rename dialog to show.
  Future<String?> rename(String title) async {
    final trimmed = title.trim();
    final accountId = state.accountId;
    final conversation = state.conversation;
    if (trimmed.isEmpty) return 'A name is needed.';
    if (accountId == null || conversation == null) {
      return 'No conversation is open.';
    }
    final gen = _generation;
    final result =
        await _repo.renameConversation(accountId, conversation, trimmed);
    return result.match(
      (f) => f is AuthFailure || f is NetworkFailure
          ? _messageOf(f)
          : 'Could not rename it: ${f.message}',
      (renamed) {
        if (gen == _generation && !isClosed) {
          emit(state.copyWith(conversation: () => renamed));
        }
        return null;
      },
    );
  }

  /// Points a composer — the thread's when [inThread] — at [m]: its next
  /// [saveEdit] replaces [m]'s text.
  void startEdit(ChatMessage m, {bool inThread = false}) {
    if (!canEdit(m) || state.sending) return;
    emit(state.copyWith(
        editing: () => m, editingInThread: inThread, error: () => null));
  }

  void cancelEdit() {
    if (state.editing != null) emit(state.copyWith(editing: () => null));
  }

  /// The newest of the user's messages that can be edited — in the open
  /// thread (its replies, then its post) when [inThread] — for Up in an
  /// empty composer.
  ChatMessage? lastEditable({required bool inThread}) => inThread
      ? [...state.threadReplies.reversed, ?state.threadPost]
          .where(canEdit)
          .firstOrNull
      : state.messages.where(canEdit).firstOrNull;

  /// Replaces the text of the message being edited
  /// ([ChatConversationState.editing]) with [text].
  Future<bool> saveEdit(String text) async {
    final trimmed = text.trim();
    final accountId = state.accountId;
    final conversation = state.conversation;
    final target = state.editing;
    if (trimmed.isEmpty ||
        accountId == null ||
        conversation == null ||
        target == null ||
        state.sending) {
      return false;
    }
    return _saveEdit(accountId, conversation, target, trimmed);
  }

  Future<bool> _saveEdit(String accountId, ChatConversation conversation,
      ChatMessage target, String text) async {
    if (text == target.editableText?.trim()) {
      cancelEdit();
      return true;
    }
    final gen = _generation;
    emit(state.copyWith(sending: true, error: () => null));
    final result =
        await _repo.editMessage(accountId, conversation, target, text);
    if (gen != _generation || isClosed) return false;
    return result.match(
      (f) {
        // The edit stays open with the text, to try again or cancel. A
        // refusal is about this message (too old, a policy), not chat as a
        // whole, so it is not worded as [_messageOf] words a 403.
        final why = f is AuthFailure || f is NetworkFailure
            ? _messageOf(f)
            : 'Could not edit the message: ${f.message}';
        emit(state.copyWith(sending: false, error: () => why));
        return false;
      },
      (edited) {
        _swap(edited.id, (_) => edited,
            (s) => s.copyWith(sending: false, editing: () => null));
        return true;
      },
    );
  }

  /// [state] with message [id] — in the list, under its post, or in the open
  /// thread — replaced by [change] of it, then [also], emitted and cached.
  void _swap(
    String id,
    ChatMessage Function(ChatMessage) change, [
    ChatConversationState Function(ChatConversationState)? also,
  ]) {
    ChatMessage swap(ChatMessage m) => m.id == id
        ? change(m)
        : m.replies.any((r) => r.id == id)
            ? m.withReplies([for (final r in m.replies) swap(r)])
            : m;
    final next = state.copyWith(
      messages: [for (final m in state.messages) swap(m)],
      threadReplies: [for (final m in state.threadReplies) swap(m)],
    );
    emit(also == null ? next : also(next));
    _cache();
  }

  /// Whether the user can react to [m] — anyone's message, not a deleted or
  /// system one.
  bool canReact(ChatMessage m) {
    final accountId = state.accountId;
    final conversation = state.conversation;
    return accountId != null &&
        conversation != null &&
        !m.isDeleted &&
        !m.isSystem &&
        _repo.canReact(accountId, conversation);
  }

  /// Whether [r] is known to include the user's own reaction.
  bool isOwnReaction(ChatReaction r) {
    final own = state.ownUserId;
    return own != null && r.userIds.contains(own);
  }

  /// Adds the user's [emoji] reaction to [m]. Nothing when the user's is
  /// already there (as far as the provider says who reacted); counted once
  /// the server has it, and only if it was new.
  Future<void> react(ChatMessage m, String emoji) async {
    final accountId = state.accountId;
    final conversation = state.conversation;
    if (!canReact(m) || accountId == null || conversation == null) return;
    bool given(ChatMessage x) =>
        x.reactions.any((r) => r.emoji == emoji && isOwnReaction(r));
    if (given(m)) return;
    final gen = _generation;
    final result = await _repo.react(accountId, conversation, m, emoji);
    if (gen != _generation || isClosed) return;
    result.match(
      (f) => emit(state.copyWith(
          error: () => f is AuthFailure || f is NetworkFailure
              ? _messageOf(f)
              : 'Could not add the reaction: ${f.message}')),
      (added) {
        final own = state.ownUserId;
        if (!added) {
          // Already the user's (Google names no one who reacted): say so,
          // so the next tap takes it off.
          if (own != null) _swap(m.id, (x) => x.withReactor(emoji, own));
          return;
        }
        // A poll may have brought the reaction in while the call ran.
        _swap(m.id,
            (x) => given(x) ? x : x.withReaction(emoji, state.ownUserId));
      },
    );
  }

  /// Takes the user's own [emoji] reaction off [m] — only one known to be
  /// theirs ([isOwnReaction]). Taken off here once the server has done it;
  /// gone from the server already, it goes here too.
  Future<void> unreact(ChatMessage m, String emoji) async {
    final accountId = state.accountId;
    final conversation = state.conversation;
    if (!canReact(m) || accountId == null || conversation == null) return;
    bool given(ChatMessage x) =>
        x.reactions.any((r) => r.emoji == emoji && isOwnReaction(r));
    if (!given(m)) return;
    final gen = _generation;
    final result = await _repo.unreact(accountId, conversation, m, emoji);
    if (gen != _generation || isClosed) return;
    result.match(
      (f) => emit(state.copyWith(
          error: () => f is AuthFailure || f is NetworkFailure
              ? _messageOf(f)
              : 'Could not remove the reaction: ${f.message}')),
      // A poll may have taken it off while the call ran.
      (_) => _swap(m.id,
          (x) => given(x) ? x.withoutReaction(emoji, state.ownUserId) : x),
    );
  }

  /// Sends [text] to the open conversation — to the open thread when
  /// [inThread] (the thread's composer) — or starts the one-on-one with
  /// [ChatConversationState.person]. Never touches an edit in progress: the
  /// composer that holds it calls [saveEdit] instead. The list's composer
  /// never answers in a thread, even with one open beside it. [image] goes
  /// with the text, which may then be empty; only where [canSendImage].
  /// [mentions] are the people picked from the `@` typeahead
  /// ([mentionable]); any still written as `@Name` are tagged.
  /// True when the server took it — even if the user has since opened
  /// another conversation, so the composer can drop its draft.
  Future<bool> send(
    String text, {
    bool inThread = false,
    ChatOutgoingImage? image,
    List<ChatMember> mentions = const [],
  }) async {
    final trimmed = text.trim();
    final accountId = state.accountId;
    if ((trimmed.isEmpty && image == null) ||
        accountId == null ||
        state.sending) {
      return false;
    }
    if (image != null && !canSendImage) {
      emit(state.copyWith(
          error: () => 'Pictures cannot be sent in this conversation.'));
      return false;
    }
    final gen = _generation;
    emit(state.copyWith(sending: true, error: () => null));

    final conversation = state.conversation;
    final person = state.person;
    if (conversation == null) {
      if (person == null) {
        emit(state.copyWith(sending: false));
        return false;
      }
      final started = await _repo.startOneOnOne(
          accountId, person.email, person.name, trimmed);
      // Moved off meanwhile: nothing to show, but it went.
      if (gen != _generation || isClosed) return started.isRight();
      return started.match(
        (f) {
          emit(state.copyWith(sending: false, error: () => _messageOf(f)));
          return false;
        },
        (r) {
          final (chat, sent) = r;
          emit(state.copyWith(
            sending: false,
            conversation: () => chat,
            messages: [sent],
          ));
          unawaited(_learnOwnId(accountId, chat, gen));
          _startPolling(gen);
          return true;
        },
      );
    }

    final threadPost = inThread && threads ? state.threadPost : null;
    final threadId = threadPost?.id;
    final sent = await _repo.sendMessage(accountId, conversation, trimmed,
        replyTo: threadPost, image: image, mentions: mentions);
    if (gen != _generation || isClosed) return sent.isRight();
    return sent.match(
      (f) {
        emit(state.copyWith(sending: false, error: () => _messageOf(f)));
        return false;
      },
      (m) {
        if (threadId != null) {
          // The post counts it at once; its "N replies" was the server's.
          _swap(threadId, (p) => p.withOneMoreReply(),
              (s) => s.copyWith(
                  sending: false, threadReplies: [...s.threadReplies, m]));
        } else {
          emit(state.copyWith(sending: false, messages: [m, ...state.messages]));
          _cache();
        }
        return true;
      },
    );
  }

  /// The roster [mentionable] fetched, per `account|conversation` — asked
  /// once on the first `@` and kept while the cubit lives.
  final _rosters = <String, Future<List<ChatMember>>>{};

  /// Who the open conversation's composer can tag with `@`: its members as
  /// the provider lists them, then anyone who has written in it that the
  /// roster missed (all there is for a Microsoft 365 channel, whose roster
  /// needs a scope NightMail does not hold), never the user. Empty with no
  /// conversation open — a one-on-one not yet started has nobody to tag.
  /// The roster is fetched once; the senders are read afresh each call, so
  /// someone who has just written (or an older page) is offered too.
  Future<List<ChatMember>> mentionable() async {
    final accountId = state.accountId;
    final conversation = state.conversation;
    if (accountId == null || conversation == null) return const [];
    final key = '$accountId|${conversation.id}';
    final roster = await (_rosters[key] ??= _repo
        .mentionable(accountId, conversation)
        .then((r) => r.getOrElse((_) {
              // Asked again next time, rather than an empty list for good.
              _rosters.remove(key);
              return const <ChatMember>[];
            })));
    if (isClosed || state.conversation?.id != conversation.id) return const [];
    final own = state.ownUserId;
    final seen = <String>{?own};
    final out = <ChatMember>[];
    for (final m in roster) {
      if (m.userId case final id? when seen.add(id)) out.add(m);
    }
    for (final m in [...state.threadReplies, ...state.messages]) {
      final id = m.senderUserId;
      final name = m.senderName.trim();
      if (id == null ||
          name.isEmpty ||
          m.isSystem ||
          m.isDeleted ||
          m.senderIsApp) {
        continue;
      }
      if (seen.add(id)) out.add(ChatMember(displayName: name, userId: id));
    }
    return out;
  }

  /// An `<img src>` in the open conversation, for the message renderer.
  Future<Uint8List?> image(String src) {
    final accountId = state.accountId;
    return accountId == null
        ? Future.value()
        : _repo.image(accountId, src);
  }

  /// A sender's photo, for their avatar.
  Future<Uint8List?> photo(String userId) {
    final accountId = state.accountId;
    return accountId == null
        ? Future.value()
        : _repo.photo(accountId, userId);
  }

  /// Whether a message in the open conversation can be answered in a thread
  /// of its own: a channel's post, a threaded space's, and a Slack DM's.
  bool get threads {
    final accountId = state.accountId;
    final conversation = state.conversation;
    if (conversation == null) return false;
    return conversation.hasThreads ||
        (accountId != null && _repo.canThread(accountId, conversation));
  }

  /// Opens a post's (or, where [threads], a message's) replies.
  Future<void> openThread(String postId) async {
    final post = state.messages.where((m) => m.id == postId).firstOrNull;
    emit(state.copyWith(
      threadPostId: () => postId,
      threadReplies: post?.replies ?? const [],
      threadLoading: true,
      editing: state.editingInThread ? () => null : null,
      editingInThread: false,
    ));
    await _reloadThread(_generation);
  }

  void closeThread() => emit(state.copyWith(
      threadPostId: () => null,
      threadReplies: const [],
      threadLoading: false,
      editing: state.editingInThread ? () => null : null,
      editingInThread: false));

  Future<void> _reloadThread(int gen) async {
    final accountId = state.accountId;
    final conversation = state.conversation;
    final postId = state.threadPostId;
    final post = state.threadPost;
    if (accountId == null ||
        conversation == null ||
        postId == null ||
        post == null) {
      return;
    }
    final replies = await _repo.replies(accountId, conversation, post);
    if (gen != _generation || isClosed || state.threadPostId != postId) return;
    replies.match(
      (f) => emit(state.copyWith(threadLoading: false, error: () => _messageOf(f))),
      (r) {
        emit(state.copyWith(threadReplies: r, threadLoading: false));
        _markReadIfSeen();
      },
    );
  }

  void _fail(Failure f) {
    final server = f is ServerFailure ? f.statusCode : null;
    emit(state.copyWith(
      loading: false,
      sending: false,
      // A server answering chat routes with 400/501 has no chat to offer.
      unavailable: server == 400 || server == 501 || f is UnsupportedFailure,
      error: () => _messageOf(f),
    ));
  }

  static String _messageOf(Failure f) => switch (f) {
        AuthFailure() => 'Sign in again to use chat (Settings > Accounts).',
        NetworkFailure() => 'Offline — chat will load when you reconnect.',
        ServerFailure(statusCode: 403) =>
          'Chat is not enabled for this account.',
        _ => f.message,
      };

  @override
  Future<void> close() {
    _lifecycle?.dispose();
    _poll?.cancel();
    return super.close();
  }
}
