import 'package:connectivity_plus/connectivity_plus.dart';

/// Cheap, OS-level "do we have a network interface up" check — not a live
/// reachability probe. Used to skip network calls outright while offline
/// instead of waiting on an HTTP client's connect timeout (tens of seconds)
/// before falling back to the cache.
abstract interface class ConnectivityService {
  Future<bool> get isOnline;

  /// Emits `true` each time connectivity transitions from offline to online
  /// (not on every OS connectivity event — e.g. switching Wi-Fi networks
  /// while already online doesn't fire this).
  Stream<void> get onReconnected;
}

class ConnectivityServiceImpl implements ConnectivityService {
  ConnectivityServiceImpl(this._connectivity);

  final Connectivity _connectivity;

  @override
  Future<bool> get isOnline async {
    final results = await _connectivity.checkConnectivity();
    return _hasConnection(results);
  }

  @override
  Stream<void> get onReconnected {
    var wasOnline = true;
    return _connectivity.onConnectivityChanged
        .map(_hasConnection)
        .where((online) {
      final justReconnected = online && !wasOnline;
      wasOnline = online;
      return justReconnected;
    });
  }

  static bool _hasConnection(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);
}
