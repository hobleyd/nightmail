import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/local_attachment.dart';

/// A file handed to NightMail through the OS share sheet, already copied by
/// the native side into storage the app owns.
class SharedFile {
  const SharedFile({
    required this.path,
    required this.name,
    this.mimeType,
  });

  final String path;
  final String name;
  final String? mimeType;
}

/// What another app shared to NightMail: Android's `ACTION_SEND` /
/// `ACTION_SEND_MULTIPLE`, or the iOS Share Extension.
class SharedContent {
  const SharedContent({
    this.subject = '',
    this.text = '',
    this.files = const [],
  });

  final String subject;
  final String text;
  final List<SharedFile> files;

  bool get isEmpty => subject.isEmpty && text.isEmpty && files.isEmpty;

  /// The map both native sides send. Anything malformed reads as empty rather
  /// than failing, so a bad share opens nothing instead of throwing.
  static SharedContent fromMap(Object? raw) {
    if (raw is! Map) return const SharedContent();
    final files = <SharedFile>[];
    final rawFiles = raw['files'];
    if (rawFiles is List) {
      for (final f in rawFiles) {
        if (f is! Map) continue;
        final path = f['path'];
        if (path is! String || path.isEmpty) continue;
        final name = f['name'];
        files.add(SharedFile(
          path: path,
          name: name is String && name.isNotEmpty
              ? name
              : path.split(Platform.pathSeparator).last,
          mimeType: f['mimeType'] as String?,
        ));
      }
    }
    return SharedContent(
      subject: (raw['subject'] as String?)?.trim() ?? '',
      text: (raw['text'] as String?)?.trim() ?? '',
      files: files,
    );
  }
}

/// Receives content shared to NightMail from other apps (Android, iOS).
///
/// The native side holds the latest share until Dart takes it, and pings
/// `shareReceived` when one arrives while the app is running. Dart always
/// *pulls* with [takePendingShare] — on start-up for a share that launched the
/// app, and on each ping — so a share that lands before the home page is
/// listening is not lost, and none is delivered twice.
class ShareIntentService {
  static const _channel =
      MethodChannel('au.com.sharpblue.nightmail/share_intent');

  StreamController<void>? _arrivals;

  /// Fires when a share arrives while the app is running.
  Stream<void> get arrivals {
    if (_arrivals == null) {
      _arrivals = StreamController<void>.broadcast();
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'shareReceived') _arrivals!.add(null);
        return null;
      });
    }
    return _arrivals!.stream;
  }

  /// The share waiting to be opened, cleared on the native side as it is
  /// taken. Null when there is none.
  Future<SharedContent?> takePendingShare() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('takePendingShare');
      if (raw == null) return null;
      final content = SharedContent.fromMap(raw);
      return content.isEmpty ? null : content;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('[Share] takePendingShare failed: $e');
      return null;
    }
  }

  /// Reads each shared file into an attachment and deletes the copy the
  /// native side made — the bytes are all compose needs from here on. A file
  /// that has gone missing is skipped.
  Future<List<LocalAttachment>> readAttachments(SharedContent content) async {
    final out = <LocalAttachment>[];
    for (final f in content.files) {
      final file = File(f.path);
      try {
        final bytes = await file.readAsBytes();
        out.add(LocalAttachment(
          name: f.name,
          mimeType: f.mimeType ?? LocalAttachment.mimeTypeFromName(f.name),
          bytes: bytes,
        ));
      } on FileSystemException catch (e) {
        debugPrint('[Share] could not read ${f.path}: $e');
      }
      try {
        await file.delete();
      } on FileSystemException {
        // Already gone, or the OS will reclaim it with the cache.
      }
    }
    return out;
  }
}
