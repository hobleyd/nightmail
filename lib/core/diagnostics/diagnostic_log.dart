import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/app_data_directory.dart';

/// A rolling copy of everything this engine says through [debugPrint], kept in
/// the app data directory so a fault leaves evidence behind without anyone
/// having relaunched the app to watch for it.
///
/// The installed macOS app runs with stdout and stderr on `/dev/null` — that is
/// what launchd gives a Finder-launched app — so until this existed the only
/// way to see a `[NightMail] … error` line from a real session was to quit the
/// app and relaunch it with `open --stdout`, which is also the one thing that
/// makes an intermittent fault go away. The 2026-10-01 report of a recipient
/// typeahead that opened nothing in reply windows, worked in new-mail windows
/// and cleared on restart went unexplained for exactly that reason.
///
/// Every engine installs its own: a `desktop_multi_window` sub-window is a
/// fresh isolate with its own [debugPrint], and all of them append to the one
/// `diagnostics.log` next to the cache database, each line stamped with the
/// time and the window that wrote it. The file is renamed to
/// `diagnostics.log.1` (replacing the previous one) once it passes [maxBytes],
/// so the pair bounds the space used. Appends are whole batches of lines
/// through `O_APPEND`, so two engines writing at once interleave by line, not
/// mid-line; two engines rotating at once is best effort and can lose a few
/// lines, which is acceptable for a diagnostic.
///
/// Deliberately not a logging framework: it tees the callback that already
/// exists and keeps whatever is given to it, unfiltered — every `debugPrint`
/// in the app is already a diagnostic, including the framework's own error
/// dumps. Nothing in here calls [debugPrint] itself (it would recurse), and
/// nothing in here throws: failing to log is the one error that stays silent.
class DiagnosticLog {
  DiagnosticLog({
    required this.windowLabel,
    required this._directory,
    this.maxBytes = defaultMaxBytes,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const String fileName = 'diagnostics.log';
  static const String rotatedFileName = 'diagnostics.log.1';
  static const int defaultMaxBytes = 512 * 1024;

  /// Lines kept in memory until [open] has found the directory. Startup says
  /// little, so this is headroom rather than a budget; past it the oldest go.
  static const int maxPendingLines = 500;

  static DiagnosticLog? _installed;

  /// The log [install] put behind [debugPrint] in this engine, if any.
  static DiagnosticLog? get installed => _installed;

  /// Puts a log for this engine behind [debugPrint]. Lines are held in memory
  /// until [start] is called — the data directory is only safe to resolve
  /// once `main()` has run the migrations that decide where it is, and
  /// nothing said before then should be lost.
  static DiagnosticLog install({required String windowLabel}) {
    _installed?.detach();
    final log = DiagnosticLog(
      windowLabel: windowLabel,
      directory: appDataDirectory,
    );
    log.attach();
    _installed = log;
    return log;
  }

  /// Resolves the directory for the log [install] created and writes out what
  /// has been said so far. A no-op when nothing is installed.
  static void start() => _installed?.open();

  /// Names the window in every line: `main`, or `window <id>` for a sub-window.
  final String windowLabel;

  /// Size at which the file is rotated to [rotatedFileName].
  final int maxBytes;

  final Future<Directory> Function() _directory;
  final DateTime Function() _now;

  final List<String> _pending = [];
  Future<void> _work = Future<void>.value();
  bool _opening = false;
  bool _open = false;
  bool _failed = false;
  Directory? _dir;
  RandomAccessFile? _handle;
  int _bytes = 0;
  DebugPrintCallback? _previous;

  /// Where the lines go, once [open] has found the directory.
  File? get file => _fileNamed(fileName);

  /// Where the previous [maxBytes] of lines went, if the log has rotated.
  File? get rotatedFile => _fileNamed(rotatedFileName);

  File? _fileNamed(String name) {
    final dir = _dir;
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// Tees [debugPrint] through [record], keeping whatever it did before.
  void attach() {
    if (_previous != null) return;
    final previous = debugPrint;
    _previous = previous;
    debugPrint = (String? message, {int? wrapWidth}) {
      previous(message, wrapWidth: wrapWidth);
      record(message);
    };
  }

  /// Puts [debugPrint] back as [attach] found it.
  void detach() {
    final previous = _previous;
    if (previous == null) return;
    debugPrint = previous;
    _previous = null;
  }

  /// Queues [message] for the file. Never throws.
  void record(String? message) {
    if (_failed || message == null) return;
    try {
      _pending.add(_format(message));
      if (_pending.length > maxPendingLines) _pending.removeAt(0);
      if (_open) _schedule();
    } catch (_) {
      // A line that cannot even be formatted is not worth the log.
    }
  }

  /// Finds the directory, then writes everything queued since [attach].
  void open() {
    if (_opening || _failed) return;
    _opening = true;
    _work = _work.then((_) async {
      try {
        _dir = await _directory();
        _open = true;
        await _write();
      } catch (_) {
        _giveUp();
      }
    });
  }

  /// Completes once everything recorded so far is on disk — or dropped, if
  /// the file side has failed. Before [open], completes at once with the
  /// lines still held.
  Future<void> flush() {
    if (_open) _schedule();
    return _work;
  }

  /// [detach], [flush] and let the file go.
  Future<void> close() async {
    detach();
    await flush();
    try {
      await _handle?.close();
    } catch (_) {}
    _handle = null;
    _open = false;
    if (identical(_installed, this)) _installed = null;
  }

  void _schedule() {
    _work = _work.then((_) => _write());
  }

  Future<void> _write() async {
    if (_failed || _pending.isEmpty) return;
    final batch = '${_pending.join('\n')}\n';
    _pending.clear();
    try {
      final bytes = utf8.encode(batch);
      final handle = await _openHandle(incoming: bytes.length);
      await handle.writeFrom(bytes);
      await handle.flush();
      _bytes += bytes.length;
    } catch (_) {
      _giveUp();
    }
  }

  Future<RandomAccessFile> _openHandle({required int incoming}) async {
    final target = file!;
    var handle = _handle;
    if (handle == null) {
      _bytes = target.existsSync() ? target.lengthSync() : 0;
    }
    // Rotate before the write that would pass the cap, never on an empty file
    // (a batch larger than the cap is written whole rather than lost).
    if (_bytes > 0 && _bytes + incoming > maxBytes) {
      await handle?.close();
      handle = null;
      _rotate(target);
    }
    if (handle == null) {
      handle = await target.open(mode: FileMode.append);
      _handle = handle;
    }
    return handle;
  }

  void _rotate(File target) {
    final rotated = rotatedFile!;
    if (rotated.existsSync()) rotated.deleteSync();
    // Another engine may have rotated it from under us; then there is nothing
    // to move and the fresh file it started is the one to append to.
    if (target.existsSync()) target.renameSync(rotated.path);
    _bytes = 0;
  }

  void _giveUp() {
    _failed = true;
    _pending.clear();
    try {
      _handle?.closeSync();
    } catch (_) {}
    _handle = null;
  }

  /// `2026-10-01T15:21:53.123 [main] first line`, with any further lines of
  /// the message indented under it so a stack trace reads as one entry.
  String _format(String message) {
    var stamp = _now().toIso8601String();
    if (stamp.length > 23) stamp = stamp.substring(0, 23);
    final lines = message.split('\n');
    final out = StringBuffer('$stamp [$windowLabel] ${lines.first}');
    for (final line in lines.skip(1)) {
      out
        ..write('\n    ')
        ..write(line);
    }
    return out.toString();
  }
}
