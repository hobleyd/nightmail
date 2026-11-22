import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/datasources/remote/change_stream_datasource.dart';
import '../accounts/account.dart';

/// Where an account's change stream is: its server's `changesUrl`, and the
/// shared mailbox it watches (null for the account's own mailbox).
typedef ChangeStreamTarget = ({String url, String? mailbox});

/// Something a change stream told us about one account.
class ChangeSignal {
  const ChangeSignal(this.accountId, this.areas, {this.isReady = false});

  final String accountId;

  /// The areas that changed (`mail`, `calendar`); on a [isReady] signal, the
  /// areas the server will watch from now on.
  final Set<String> areas;

  /// A (re)connection just finished reading its baseline. Nothing between the
  /// last sync and this moment was signalled, so whoever syncs an area syncs
  /// it once now.
  final bool isReady;

  bool concerns(String area) => areas.contains(area);

  @override
  String toString() =>
      'ChangeSignal($accountId, ${isReady ? 'ready ' : ''}${areas.join(',')})';
}

/// Holds a NightMail Server's change stream open for every account whose
/// server publishes one (nightware ADR 0007), and turns what they say into
/// [signals] — so the poller syncs within seconds of a change instead of at
/// its next tick.
///
/// A signal is only ever a reason to sync sooner. Nothing depends on one
/// arriving: the poller's timer keeps running, a dropped connection is
/// reconnected with backoff, and an account whose server publishes no stream
/// (or a Microsoft or Gmail account) is simply never watched.
///
/// Main window only, like IMAP IDLE: a sub-window must not hold long-lived
/// connections of its own. [watch] is called at the end of every poll cycle
/// with the current accounts, which is both how new accounts get a stream and
/// how removed ones lose theirs.
class ChangeStreamService {
  ChangeStreamService({
    required this._targetFor,
    required this._open,
    Duration Function(int failures)? backoff,
  }) : _backoff = backoff ?? defaultBackoff;

  final ChangeStreamTarget? Function(Account account) _targetFor;
  final Stream<ChangeStreamEvent> Function(Account account) _open;
  final Duration Function(int failures) _backoff;

  final _signals = StreamController<ChangeSignal>.broadcast();
  final Map<String, _Connection> _connections = {};
  bool _disposed = false;

  /// Every account's signals, as they arrive.
  Stream<ChangeSignal> get signals => _signals.stream;

  /// The account ids with a stream connected or reconnecting — for tests and
  /// diagnostics.
  Set<String> get watchedAccountIds => _connections.keys.toSet();

  /// The pause before reconnecting after [failures] consecutive failures: 2 s
  /// doubling to 2 min. A clean close by the server (`end`, or the connection
  /// ending after a `ready`) is not a failure and reconnects after 1 s.
  static Duration defaultBackoff(int failures) {
    if (failures <= 0) return const Duration(seconds: 1);
    final seconds = 2 << (failures - 1).clamp(0, 6);
    return Duration(seconds: seconds > 120 ? 120 : seconds);
  }

  /// Watches exactly [accounts] that have a change stream: connects the new
  /// ones, keeps the ones already connected to the same place, and closes the
  /// rest. Idempotent; cheap to call every poll cycle.
  void watch(Iterable<Account> accounts) {
    if (_disposed) return;
    final wanted = <String, (Account, ChangeStreamTarget)>{};
    for (final account in accounts) {
      final target = _targetFor(account);
      if (target != null) wanted[account.id] = (account, target);
    }
    for (final id in _connections.keys.toList()) {
      final keep = wanted[id];
      if (keep == null || keep.$2 != _connections[id]!.target) {
        _connections.remove(id)!.close();
      }
    }
    for (final MapEntry(key: id, value: (account, target)) in wanted.entries) {
      _connections.putIfAbsent(id, () {
        debugPrint('[ChangeStream] $id: watching ${target.url}'
            '${target.mailbox == null ? '' : ' for ${target.mailbox}'}');
        return _Connection(
          account: account,
          target: target,
          open: _open,
          backoff: _backoff,
          emit: (signal) {
            if (!_signals.isClosed) _signals.add(signal);
          },
        )..start();
      });
    }
  }

  /// Closes every connection; [signals] completes.
  Future<void> dispose() async {
    _disposed = true;
    for (final c in _connections.values) {
      c.close();
    }
    _connections.clear();
    await _signals.close();
  }
}

/// One account's stream: connect, relay, and reconnect after it ends.
class _Connection {
  _Connection({
    required this.account,
    required this.target,
    required this._open,
    required this._backoff,
    required this._emit,
  });

  final Account account;
  final ChangeStreamTarget target;
  final Stream<ChangeStreamEvent> Function(Account) _open;
  final Duration Function(int) _backoff;
  final void Function(ChangeSignal) _emit;

  StreamSubscription<ChangeStreamEvent>? _subscription;
  Timer? _retry;
  int _failures = 0;
  bool _ready = false;
  bool _closed = false;

  void start() {
    if (_closed) return;
    _ready = false;
    try {
      _subscription = _open(account).listen(
        _onEvent,
        onError: (Object e) => _ended(error: e),
        onDone: () => _ended(),
        cancelOnError: true,
      );
    } catch (e) {
      _ended(error: e);
    }
  }

  void _onEvent(ChangeStreamEvent event) {
    switch (event) {
      case ChangeStreamReady(:final areas):
        _ready = true;
        _failures = 0;
        _emit(ChangeSignal(account.id, areas, isReady: true));
      case ChangeStreamChanged(:final areas):
        _emit(ChangeSignal(account.id, areas));
      case ChangeStreamEnded(:final reason):
        debugPrint('[ChangeStream] ${account.id}: server closed ($reason)');
    }
  }

  /// The connection is over, cleanly or not. A stream that got as far as
  /// `ready` and then closed is the server's normal lifecycle (token expiry,
  /// maximum age) and reconnects at once; one that failed before `ready` backs
  /// off, so a server answering 404 or 429 is asked again in minutes, not in a
  /// loop.
  void _ended({Object? error}) {
    _subscription = null;
    if (_closed) return;
    if (error != null || !_ready) {
      _failures++;
      debugPrint('[ChangeStream] ${account.id}: '
          '${error == null ? 'closed before ready' : 'failed: $error'}; '
          'retry #$_failures in ${_backoff(_failures).inSeconds} s');
    }
    _retry = Timer(_backoff(_ready && error == null ? 0 : _failures), start);
  }

  void close() {
    _closed = true;
    _retry?.cancel();
    _subscription?.cancel();
    _subscription = null;
  }
}
