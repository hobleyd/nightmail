import 'dart:async';
import 'dart:io';

/// Cheap "do we have a route to the internet" check — not a full
/// reachability guarantee, but enough to skip network calls outright while
/// offline instead of waiting on an HTTP client's connect timeout (tens of
/// seconds) before falling back to the cache.
///
/// Deliberately implemented with a raw TCP connection attempt (dart:io)
/// rather than a platform-channel plugin (connectivity_plus was tried
/// first): the plugin's native call reliably hung indefinitely in this app
/// under macOS's "merged UI and platform thread" engine mode, even behind a
/// Dart-side timeout — the hang was inside the platform channel round-trip
/// itself, not something a Future.timeout() on the Dart side could
/// interrupt. A raw socket connect runs entirely in the Dart VM's own I/O,
/// so it isn't subject to that deadlock.
///
/// Connects to a hardcoded IP, not a hostname: an early version did a DNS
/// lookup instead, which can return a stale cached answer for a
/// still-resolvable hostname even with no real route to the internet,
/// producing a false "online" that then let the real network call behind
/// it run out its own much longer timeout anyway.
abstract interface class ConnectivityService {
  Future<bool> get isOnline;

  /// Emits `true` each time connectivity transitions from offline to online
  /// (polled — see [_pollInterval] — not a live OS push notification).
  Stream<void> get onReconnected;
}

class ConnectivityServiceImpl implements ConnectivityService {
  // Cloudflare's public DNS resolver — chosen only for being a stable,
  // well-known IP that answers on 443; no DNS involved.
  static const _probeIp = '1.1.1.1';
  static const _probePort = 443;
  static const _timeout = Duration(seconds: 3);
  static const _pollInterval = Duration(seconds: 15);

  @override
  Future<bool> get isOnline async {
    try {
      final socket =
          await Socket.connect(_probeIp, _probePort, timeout: _timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<void> get onReconnected async* {
    var wasOnline = await isOnline;
    while (true) {
      await Future<void>.delayed(_pollInterval);
      final nowOnline = await isOnline;
      if (nowOnline && !wasOnline) yield null;
      wasOnline = nowOnline;
    }
  }
}
