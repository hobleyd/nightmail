import 'package:flutter/services.dart';

const _channel = MethodChannel('au.com.sharpblue.nightmail/clipboard');

/// A picture on the clipboard, as [readClipboardImage] finds it.
typedef ClipboardImage = ({
  Uint8List bytes,
  String mimeType,
  String name,
  int? width,
  int? height,
});

/// The picture on the clipboard, or null when a paste there is text (or
/// nothing). The runner decides — `MainFlutterWindow.swift`,
/// `windows/runner/clipboard_image.cpp`, `linux/runner/clipboard_image.cc`
/// — so a copied paragraph from Word, which carries a picture of itself
/// too, still pastes as text. Mobile has no handler: a paste there is
/// always text.
Future<ClipboardImage?> readClipboardImage() async {
  try {
    final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('readImage');
    final bytes = r?['bytes'];
    if (r == null || bytes is! Uint8List || bytes.isEmpty) return null;
    return (
      bytes: bytes,
      mimeType: r['mimeType'] as String? ?? 'image/png',
      name: r['name'] as String? ?? 'image.png',
      width: (r['width'] as num?)?.toInt(),
      height: (r['height'] as num?)?.toInt(),
    );
  } catch (_) {
    return null;
  }
}
