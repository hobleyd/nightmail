import 'dart:async';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/chat.dart';
import '../../../domain/repositories/chat_repository.dart';

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
/// the user is away would be marked read in Teams too.
class ChatConversationCubit extends Cubit<ChatConversationState> {
  ChatConversationCubit({
    required ChatRepository repository,
    bool Function()? isForeground,
  })  : _repo = repository,
        _isForeground = isForeground ?? _appInForeground,
        super(const ChatConversationState());

  final ChatRepository _repo;
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

  static const pollInterval = Duration(seconds: 10);

  Timer? _poll;
  int _generation = 0;

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
    emit(ChatConversationState(
        accountId: state.accountId,
        access: state.access,
        ownUserId: state.ownUserId));
  }

  Future<void> _load(
      String accountId, ChatConversation conversation, int gen) async {
    emit(state.copyWith(conversation: () => conversation, loading: true));
    final own = _learnOwnId(accountId, conversation, gen);
    final page = await _repo.messages(accountId, conversation);
    if (gen != _generation || isClosed) return;
    page.match(
      (f) => _fail(f),
      (p) {
        emit(state.copyWith(
          messages: p.messages,
          nextLink: () => p.nextLink,
          loading: false,
          error: () => null,
        ));
        _startPolling(gen);
      },
    );
    await own;
    _markReadIfSeen();
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
    final newest = state.messages.where((m) => !m.isSystem).firstOrNull;
    if (newest == null || _markedUpTo[conversation.key] == newest.id) return;
    if (newest.senderUserId == own) {
      _markedUpTo[conversation.key] = newest.id;
      return;
    }
    if (!_isForeground()) return;
    _markedUpTo[conversation.key] = newest.id;
    unawaited(_repo.markRead(accountId, conversation));
  }

  void _startPolling(int gen) {
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) => _refresh(gen));
  }

  /// Re-reads the newest page and merges it over what is shown: new messages
  /// arrive, edits, deletions and reactions update, older pages stay.
  Future<void> _refresh(int gen) async {
    final accountId = state.accountId;
    final conversation = state.conversation;
    if (accountId == null || conversation == null) return;
    final page = await _repo.messages(accountId, conversation);
    if (gen != _generation || isClosed) return;
    page.match((_) {}, (p) {
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
      }
      _markReadIfSeen();
    });
    if (state.threadPostId != null) unawaited(_reloadThread(gen));
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
        final seen = {for (final m in state.messages) m.id};
        emit(state.copyWith(
          messages: [
            ...state.messages,
            ...p.messages.where((m) => !seen.contains(m.id)),
          ],
          nextLink: () => p.nextLink,
          loadingOlder: false,
        ));
      },
    );
  }

  /// Sends [text] to the open conversation — to the open thread when one is
  /// open — or starts the one-on-one with [ChatConversationState.person].
  Future<bool> send(String text) async {
    final trimmed = text.trim();
    final accountId = state.accountId;
    if (trimmed.isEmpty || accountId == null || state.sending) return false;
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
      if (gen != _generation || isClosed) return false;
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

    final threadPost = conversation.hasThreads ? state.threadPost : null;
    final threadId = threadPost?.id;
    final sent = await _repo.sendMessage(accountId, conversation, trimmed,
        replyTo: threadPost);
    if (gen != _generation || isClosed) return false;
    return sent.match(
      (f) {
        emit(state.copyWith(sending: false, error: () => _messageOf(f)));
        return false;
      },
      (m) {
        emit(threadId != null
            ? state.copyWith(
                sending: false, threadReplies: [...state.threadReplies, m])
            : state.copyWith(sending: false, messages: [m, ...state.messages]));
        return true;
      },
    );
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

  /// Opens a channel post's replies.
  Future<void> openThread(String postId) async {
    final post = state.messages.where((m) => m.id == postId).firstOrNull;
    emit(state.copyWith(
      threadPostId: () => postId,
      threadReplies: post?.replies ?? const [],
      threadLoading: true,
    ));
    await _reloadThread(_generation);
  }

  void closeThread() => emit(state.copyWith(
      threadPostId: () => null, threadReplies: const [], threadLoading: false));

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
      (r) => emit(state.copyWith(threadReplies: r, threadLoading: false)),
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
    _poll?.cancel();
    return super.close();
  }
}
