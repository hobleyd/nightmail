import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// A chat message's HTML as styled text — no webview.
///
/// Chat bodies are a small dialect: Teams sends `<p>`, `<b>`/`<strong>`,
/// `<i>`/`<em>`, `<u>`, `<s>`, `<code>`, `<pre>`, `<a>`, `<at>` mentions,
/// lists, `<blockquote>` and `<img>` (emoji, inline images); Nightware's
/// rendering of Talk's Markdown is the same subset (ADR 0009 D4). One
/// webview per message would not scale to a scrolling history, and a text
/// rendering cannot run script. An emoji keeps its `alt`; any other image is
/// fetched through [loadImage] — the datasource decides what may be fetched
/// and with which credentials — and reads "[image]" without one.
class ChatMessageBody extends StatefulWidget {
  const ChatMessageBody({
    super.key,
    required this.html,
    required this.style,
    this.loadImage,
  });

  final String html;
  final TextStyle style;
  final Future<Uint8List?> Function(String src)? loadImage;

  @override
  State<ChatMessageBody> createState() => _ChatMessageBodyState();
}

class _ChatMessageBodyState extends State<ChatMessageBody> {
  final _recognizers = <TapGestureRecognizer>[];
  InlineSpan? _span;
  String? _builtFor;
  Brightness? _builtBrightness;

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    if (_span == null ||
        _builtFor != widget.html ||
        _builtBrightness != brightness) {
      for (final r in _recognizers) {
        r.dispose();
      }
      _recognizers.clear();
      _span = _ChatHtml(
        base: widget.style,
        accent: Theme.of(context).colorScheme.primary,
        codeBg: Theme.of(context).colorScheme.onSurface.withAlpha(20),
        onRecognizer: _recognizers.add,
        loadImage: widget.loadImage,
      ).render(widget.html);
      _builtFor = widget.html;
      _builtBrightness = brightness;
    }
    // Selection comes from the SelectionArea the conversation view wraps
    // its history in; plain Text.rich keeps the link recognizers working.
    return Text.rich(TextSpan(children: [_span!]));
  }
}

class _ChatHtml {
  _ChatHtml({
    required this.base,
    required this.accent,
    required this.codeBg,
    required this.onRecognizer,
    this.loadImage,
  });

  final TextStyle base;
  final Color accent;
  final Color codeBg;
  final void Function(TapGestureRecognizer) onRecognizer;
  final Future<Uint8List?> Function(String src)? loadImage;

  static final _token = RegExp(r'<(/?)([a-zA-Z0-9]+)([^>]*)>|([^<]+)');
  static final _attr = RegExp(r'''([a-zA-Z-]+)\s*=\s*("([^"]*)"|'([^']*)')''');

  InlineSpan render(String html) {
    final out = <InlineSpan>[];
    final styles = <TextStyle>[base];
    final tags = <String>[];
    final hrefs = <String?>[];
    final listCounters = <int?>[];
    var atLineStart = true;

    void text(String s) {
      if (s.isEmpty) return;
      final href = hrefs.lastWhere((h) => h != null, orElse: () => null);
      TapGestureRecognizer? tap;
      if (href != null) {
        tap = TapGestureRecognizer()..onTap = () => _open(href);
        onRecognizer(tap);
      }
      out.add(TextSpan(text: s, style: styles.last, recognizer: tap));
      atLineStart = s.endsWith('\n');
    }

    void newline() {
      if (!atLineStart && out.isNotEmpty) text('\n');
    }

    void push(String tag, TextStyle style) {
      tags.add(tag);
      styles.add(style);
    }

    void pop(String tag) {
      final i = tags.lastIndexOf(tag);
      if (i < 0) return;
      tags.removeRange(i, tags.length);
      styles.removeRange(i + 1, styles.length);
    }

    final source = html.replaceAll(
      RegExp(r'<(style|script)[^>]*>.*?</\1>', caseSensitive: false, dotAll: true),
      '',
    );
    for (final m in _token.allMatches(source)) {
      final raw = m.group(4);
      if (raw != null) {
        final decoded = _decode(raw.replaceAll(RegExp(r'\s*\n\s*'), ' '));
        text(atLineStart ? decoded.trimLeft() : decoded);
        continue;
      }
      final closing = m.group(1) == '/';
      final tag = m.group(2)!.toLowerCase();
      final attrs = _attrs(m.group(3) ?? '');
      final cur = styles.last;
      if (closing) {
        switch (tag) {
          case 'p' || 'div' || 'blockquote' || 'pre' || 'li':
            newline();
          case 'ul' || 'ol':
            if (listCounters.isNotEmpty) listCounters.removeLast();
            newline();
          case 'a':
            if (hrefs.isNotEmpty) hrefs.removeLast();
        }
        pop(tag);
        continue;
      }
      switch (tag) {
        case 'br':
          text('\n');
        case 'p' || 'div':
          newline();
        case 'b' || 'strong' || 'h1' || 'h2' || 'h3' || 'h4':
          push(tag, cur.copyWith(fontWeight: FontWeight.w700));
        case 'i' || 'em':
          push(tag, cur.copyWith(fontStyle: FontStyle.italic));
        case 'u':
          push(tag, cur.copyWith(decoration: TextDecoration.underline));
        case 's' || 'strike' || 'del':
          push(tag, cur.copyWith(decoration: TextDecoration.lineThrough));
        case 'code' || 'pre':
          if (tag == 'pre') newline();
          push(tag,
              cur.copyWith(fontFamily: 'Menlo', backgroundColor: codeBg));
        case 'blockquote':
          newline();
          push(tag, cur.copyWith(color: cur.color?.withAlpha(170)));
          text('▍ ');
        case 'at':
          push(tag, cur.copyWith(color: accent, fontWeight: FontWeight.w600));
          text('@');
        case 'a':
          final href = attrs['href'];
          hrefs.add(_safeHref(href));
          push(tag, cur.copyWith(
            color: accent,
            decoration: TextDecoration.underline,
          ));
        case 'ul':
          newline();
          listCounters.add(null);
        case 'ol':
          newline();
          listCounters.add(0);
        case 'li':
          newline();
          final n = listCounters.isEmpty ? null : listCounters.last;
          if (n == null) {
            text('•  ');
          } else {
            listCounters[listCounters.length - 1] = n + 1;
            text('${n + 1}.  ');
          }
        case 'img' when attrs.containsKey('data-emoji'):
          // A workspace's own emoji (Slack): a picture the size of the text.
          final src = attrs['src'] ?? '';
          final load = loadImage;
          final alt = attrs['alt'] ?? '';
          if (load == null || src.isEmpty) {
            text(alt);
          } else {
            out.add(WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: ChatEmojiImage(
                src: src,
                load: load,
                alt: alt,
                size: (styles.last.fontSize ?? 13) * 1.35,
              ),
            ));
            atLineStart = false;
          }
        case 'img':
          final alt = attrs['alt'] ?? '';
          final isEmoji = (attrs['itemtype'] ?? '').contains('Emoji') ||
              (alt.isNotEmpty && alt.runes.length <= 3);
          final src = attrs['src'] ?? '';
          final load = loadImage;
          if (isEmoji) {
            text(alt);
          } else if (load == null || src.isEmpty) {
            text('[image]');
          } else {
            out.add(WidgetSpan(
              alignment: PlaceholderAlignment.bottom,
              child: ChatImage(
                src: src,
                load: load,
                alt: alt,
                width: double.tryParse(attrs['width'] ?? ''),
                height: double.tryParse(attrs['height'] ?? ''),
              ),
            ));
            atLineStart = false;
          }
        case 'emoji':
          text(attrs['alt'] ?? '');
      }
    }
    while (out.isNotEmpty &&
        out.last is TextSpan &&
        ((out.last as TextSpan).text ?? '').trim().isEmpty) {
      out.removeLast();
    }
    if (out.isNotEmpty && out.last is TextSpan) {
      final last = out.removeLast() as TextSpan;
      out.add(TextSpan(
        text: last.text?.trimRight(),
        style: last.style,
        recognizer: last.recognizer,
      ));
    }
    return TextSpan(children: out);
  }

  static Map<String, String> _attrs(String s) => {
        for (final m in _attr.allMatches(s))
          m.group(1)!.toLowerCase(): _decode(m.group(3) ?? m.group(4) ?? ''),
      };

  /// Only links a person would follow on purpose; anything else is text.
  static String? _safeHref(String? href) {
    final uri = href == null ? null : Uri.tryParse(href.trim());
    if (uri == null) return null;
    return const {'http', 'https', 'mailto'}.contains(uri.scheme)
        ? uri.toString()
        : null;
  }

  static void _open(String href) {
    final uri = Uri.tryParse(href);
    if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static String _decode(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#160;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAllMapped(RegExp(r'&#(\d+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!)))
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
      .replaceAll('&amp;', '&');
}

/// A workspace's own emoji: [size] square, inline with the text, its `:name:`
/// as the tooltip — and as the text while it loads or when it cannot be.
class ChatEmojiImage extends StatefulWidget {
  const ChatEmojiImage({
    super.key,
    required this.src,
    required this.load,
    required this.alt,
    required this.size,
  });

  final String src;
  final Future<Uint8List?> Function(String src) load;
  final String alt;
  final double size;

  @override
  State<ChatEmojiImage> createState() => _ChatEmojiImageState();
}

class _ChatEmojiImageState extends State<ChatEmojiImage> {
  late Future<Uint8List?> _bytes = widget.load(widget.src);

  @override
  void didUpdateWidget(ChatEmojiImage old) {
    super.didUpdateWidget(old);
    if (old.src != widget.src) _bytes = widget.load(widget.src);
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.alt,
      child: FutureBuilder<Uint8List?>(
        future: _bytes,
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null) {
            return snap.connectionState == ConnectionState.done
                ? Text(widget.alt)
                : SizedBox.square(dimension: widget.size);
          }
          return Image.memory(
            bytes,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            semanticLabel: widget.alt,
            errorBuilder: (_, _, _) => Text(widget.alt),
          );
        },
      ),
    );
  }
}

/// A picture in a message, at most [maxWidth] × [maxHeight]; tapping it opens
/// it full size. Sized from the tag's own width and height while it loads, so
/// the history does not jump; "[image]" when it cannot be fetched.
class ChatImage extends StatefulWidget {
  const ChatImage({
    super.key,
    required this.src,
    required this.load,
    this.alt = '',
    this.width,
    this.height,
  });

  final String src;
  final Future<Uint8List?> Function(String src) load;
  final String alt;
  final double? width;
  final double? height;

  static const maxWidth = 320.0;
  static const maxHeight = 260.0;

  @override
  State<ChatImage> createState() => _ChatImageState();
}

class _ChatImageState extends State<ChatImage> {
  late Future<Uint8List?> _bytes = widget.load(widget.src);

  @override
  void didUpdateWidget(ChatImage old) {
    super.didUpdateWidget(old);
    if (old.src != widget.src) _bytes = widget.load(widget.src);
  }

  /// The tag's size scaled into the bounds, or a modest box when it has none.
  Size get _placeholder {
    final w = widget.width, h = widget.height;
    if (w == null || h == null || w <= 0 || h <= 0) return const Size(160, 120);
    final scale = [1.0, ChatImage.maxWidth / w, ChatImage.maxHeight / h]
        .reduce((a, b) => a < b ? a : b);
    return Size(w * scale, h * scale);
  }

  void _open(Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            InteractiveViewer(
              maxScale: 6,
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton.filledTonal(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: FutureBuilder<Uint8List?>(
        future: _bytes,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            final size = _placeholder;
            return Container(
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(
                color: scheme.onSurface.withAlpha(15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final bytes = snap.data;
          final missing = Text(
            widget.alt.isNotEmpty ? '[image: ${widget.alt}]' : '[image]',
            style: TextStyle(fontSize: 12, color: scheme.onSurface.withAlpha(140)),
          );
          if (bytes == null) return missing;
          return MouseRegion(
            cursor: SystemMouseCursors.zoomIn,
            child: GestureDetector(
              onTap: () => _open(bytes),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: ChatImage.maxWidth,
                  maxHeight: ChatImage.maxHeight,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => missing,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
