import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// What a NightMail Server's change stream says (nightware ADR 0007): which
/// areas of a mailbox changed, never the changes themselves — those come over
/// the usual delta routes.
sealed class ChangeStreamEvent {
  const ChangeStreamEvent();
}

/// The server has read where every area stands; anything after this is
/// signalled. A change between the last sync and this is not, so the client
/// syncs once on it.
final class ChangeStreamReady extends ChangeStreamEvent {
  const ChangeStreamReady(this.areas);

  /// What the server watches for this mailbox (`mail`, `calendar`).
  final Set<String> areas;
}

/// [areas] changed since the server's previous look.
final class ChangeStreamChanged extends ChangeStreamEvent {
  const ChangeStreamChanged(this.areas);

  final Set<String> areas;
}

/// The server is closing the stream: `expired` (the token is near its expiry,
/// or the stream reached its maximum age) or `credentials` (a backend refused
/// the token). Either way, reconnect — with a fresh token.
final class ChangeStreamEnded extends ChangeStreamEvent {
  const ChangeStreamEnded(this.reason);

  final String reason;
}

/// Turns a `text/event-stream` body into [ChangeStreamEvent]s.
///
/// Only the events the change stream sends are reported: `ready`, `changed`
/// and `end`, each with one JSON `data:` line. Comment lines (the keepalive),
/// `retry:`, unknown events and data that is not the expected JSON are
/// skipped, so a server that adds an event later cannot break the client.
Stream<ChangeStreamEvent> parseChangeStream(Stream<List<int>> bytes) async* {
  String? event;
  final data = StringBuffer();
  await for (final line
      in utf8.decoder.bind(bytes).transform(const LineSplitter())) {
    if (line.isEmpty) {
      final parsed = _toEvent(event, data.toString());
      event = null;
      data.clear();
      if (parsed != null) yield parsed;
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        if (data.isNotEmpty) data.write('\n');
        data.write(value);
    }
  }
}

ChangeStreamEvent? _toEvent(String? event, String data) {
  if (event == null) return null;
  Object? json;
  try {
    json = data.isEmpty ? null : jsonDecode(data);
  } on FormatException {
    return null;
  }
  Set<String>? areas() {
    final raw = json is Map ? json['areas'] : null;
    return raw is List ? raw.whereType<String>().toSet() : null;
  }

  switch (event) {
    case 'ready':
      final a = areas();
      return a == null ? null : ChangeStreamReady(a);
    case 'changed':
      final a = areas();
      return a == null || a.isEmpty ? null : ChangeStreamChanged(a);
    case 'end':
      final reason = json is Map ? json['reason'] : null;
      return ChangeStreamEnded(reason is String ? reason : '');
  }
  return null;
}

/// Opens a NightMail Server's change stream (nightware ADR 0007) on [dio] —
/// the account's own Graph client, so the bearer token, its refresh and the
/// 401 handling are exactly those of every other call the account makes.
class ChangeStreamDatasource {
  ChangeStreamDatasource(this._dio);

  final Dio _dio;

  /// The longest the server goes without writing is its keepalive, 25 s. A
  /// connection silent for this long is gone — typically a half-open TCP
  /// connection after the machine slept — and is closed so the caller
  /// reconnects. Dio's `receiveTimeout` covers only the wait for headers.
  static const idleTimeout = Duration(seconds: 75);

  /// The events of one connection to [url], for [mailbox] (a shared mailbox's
  /// address; null for the account's own). Cancelling the subscription closes
  /// the connection. The stream ends when the server closes it, and errors on
  /// a failed request (a `DioException`, or whatever the auth interceptor
  /// throws) or after [idleTimeout] of silence.
  Stream<ChangeStreamEvent> open(String url, {String? mailbox}) {
    final cancel = CancelToken();
    late final StreamController<ChangeStreamEvent> controller;
    StreamSubscription<ChangeStreamEvent>? events;

    Future<void> start() async {
      try {
        final response = await _dio.get<ResponseBody>(
          url,
          queryParameters: {'mailbox': ?mailbox},
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Accept': 'text/event-stream'},
          ),
        );
        if (controller.isClosed) return;
        final body = response.data;
        if (body == null) {
          await controller.close();
          return;
        }
        events = parseChangeStream(body.stream)
            .timeout(idleTimeout, onTimeout: (sink) {
          sink.addError(TimeoutException(
              'The change stream was silent for ${idleTimeout.inSeconds} s',
              idleTimeout));
          sink.close();
        }).listen(
          controller.add,
          onError: (Object e, StackTrace s) {
            if (controller.isClosed) return;
            controller.addError(e, s);
            controller.close();
          },
          onDone: () {
            if (!controller.isClosed) controller.close();
          },
          cancelOnError: true,
        );
      } catch (e, s) {
        if (!controller.isClosed) {
          controller.addError(e, s);
          await controller.close();
        }
      }
    }

    controller = StreamController<ChangeStreamEvent>(
      onListen: start,
      onCancel: () async {
        cancel.cancel('change stream closed');
        await events?.cancel();
      },
    );
    return controller.stream;
  }
}
