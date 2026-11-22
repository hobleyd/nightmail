import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/change_stream_datasource.dart';

/// Answers every request with [status] and [chunks] as a streamed body, and
/// keeps the request it was given.
class _StreamingAdapter implements HttpClientAdapter {
  _StreamingAdapter(this.chunks, {this.status = 200});

  final List<String> chunks;
  final int status;
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    request = options;
    return ResponseBody(
      Stream.fromIterable(chunks.map((c) => Uint8List.fromList(utf8.encode(c)))),
      status,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Stream<List<int>> _bytes(List<String> chunks) =>
    Stream.fromIterable(chunks.map(utf8.encode));

void main() {
  group('parseChangeStream', () {
    test('reads ready, changed and end, skipping comments and retry', () async {
      final events = await parseChangeStream(_bytes([
        'retry: 10000\n\n',
        'event: ready\ndata: {"areas":["mail","calendar"]}\n\n',
        ': keepalive\n\n',
        'event: changed\ndata: {"areas":["mail"]}\n\n',
        'event: end\ndata: {"reason":"expired"}\n\n',
      ])).toList();

      expect(events, hasLength(3));
      expect((events[0] as ChangeStreamReady).areas, {'mail', 'calendar'});
      expect((events[1] as ChangeStreamChanged).areas, {'mail'});
      expect((events[2] as ChangeStreamEnded).reason, 'expired');
    });

    test('an event split across chunks, mid-line, still arrives whole',
        () async {
      final events = await parseChangeStream(_bytes([
        'event: chan',
        'ged\ndata: {"are',
        'as":["calendar"]}\n',
        '\n',
      ])).toList();

      expect((events.single as ChangeStreamChanged).areas, {'calendar'});
    });

    test('CRLF line endings are read like LF', () async {
      final events = await parseChangeStream(
              _bytes(['event: changed\r\ndata: {"areas":["mail"]}\r\n\r\n']))
          .toList();

      expect(events.single, isA<ChangeStreamChanged>());
    });

    test(
        'an unknown event, data that is not the expected JSON, and an empty '
        'change are skipped rather than breaking the stream', () async {
      final events = await parseChangeStream(_bytes([
        'event: hello\ndata: {}\n\n',
        'event: changed\ndata: not json\n\n',
        'event: changed\ndata: {"areas":[]}\n\n',
        'data: {"areas":["mail"]}\n\n',
        'event: changed\ndata: {"areas":["mail"]}\n\n',
      ])).toList();

      expect(events, hasLength(1));
      expect((events.single as ChangeStreamChanged).areas, {'mail'});
    });
  });

  group('ChangeStreamDatasource', () {
    test(
        'asks for an event stream, names a shared mailbox, and relays the '
        'events until the server closes', () async {
      final adapter = _StreamingAdapter([
        'event: ready\ndata: {"areas":["mail"]}\n\n',
        'event: changed\ndata: {"areas":["mail"]}\n\n',
      ]);
      final dio = Dio()..httpClientAdapter = adapter;

      final events = await ChangeStreamDatasource(dio)
          .open('https://mail.example.com/graph/nightware/v1/changes',
              mailbox: 'support@example.com')
          .toList();

      expect(events.map((e) => e.runtimeType),
          [ChangeStreamReady, ChangeStreamChanged]);
      expect(adapter.request!.headers['Accept'], 'text/event-stream');
      expect(adapter.request!.uri.queryParameters['mailbox'],
          'support@example.com');
    });

    test("the account's own mailbox sends no mailbox parameter", () async {
      final adapter = _StreamingAdapter(const []);
      final dio = Dio()..httpClientAdapter = adapter;

      await ChangeStreamDatasource(dio)
          .open('https://mail.example.com/graph/nightware/v1/changes')
          .toList();

      expect(adapter.request!.uri.queryParameters, isEmpty);
    });

    test('a refused request is an error on the stream, then it ends',
        () async {
      final dio = Dio()..httpClientAdapter = _StreamingAdapter(const [], status: 404);

      final done = Completer<Object?>();
      ChangeStreamDatasource(dio)
          .open('https://mail.example.com/graph/nightware/v1/changes')
          .listen((_) {}, onError: (Object e) {
        if (!done.isCompleted) done.complete(e);
      }, onDone: () {
        if (!done.isCompleted) done.complete(null);
      });

      expect(await done.future, isA<DioException>());
    });
  });
}
