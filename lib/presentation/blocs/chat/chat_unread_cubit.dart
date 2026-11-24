import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/repositories/chat_repository.dart';
import '../../../infrastructure/accounts/account_manager.dart';

/// How many of the active account's chats have something the user has not
/// read — the number behind the dot on the Chat button.
///
/// Nothing pushes chat to NightMail, so this polls: one page of recent chats
/// every [pollInterval] ([ChatRepository.unreadCount]). A chat read in this
/// window clears at once ([ChatRepository.reads]); one read in the chat
/// window — its own isolate — or in Teams clears on the next poll.
class ChatUnreadCubit extends Cubit<int> {
  ChatUnreadCubit({
    required this._accountManager,
    required this._repository,
  }) : super(0);

  final AccountManager _accountManager;
  final ChatRepository _repository;

  static const pollInterval = Duration(seconds: 60);

  Timer? _timer;
  StreamSubscription<String>? _reads;

  /// Bumped per [refresh] so a slow answer for the account being left never
  /// lands after the arriving one's.
  int _generation = 0;

  /// Safe to call repeatedly — HomePage calls it on every build.
  void start() {
    _reads ??= _repository.reads.listen((accountId) {
      if (accountId == _accountManager.activeAccount?.id) unawaited(refresh());
    });
    if (_timer != null) return;
    _timer = Timer.periodic(pollInterval, (_) => refresh());
    unawaited(refresh());
  }

  Future<void> refresh() async {
    final gen = ++_generation;
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) {
      if (!isClosed) emit(0);
      return;
    }
    final count = await _repository.unreadCount(accountId);
    if (gen == _generation && !isClosed) emit(count);
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    _reads?.cancel();
    return super.close();
  }
}
