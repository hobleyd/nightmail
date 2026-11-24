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
/// rendering cannot run script or fetch anything: images are never loaded —
/// an emoji keeps its `alt`, anything else reads "[image]".
class ChatMessageBody extends StatefulWidget {
  const ChatMessageBody({super.key, required this.html, required this.style});

  final String html;
  final TextStyle style;

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
  });

  final TextStyle base;
  final Color accent;
  final Color codeBg;
  final void Function(TapGestureRecognizer) onRecognizer;

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
        case 'img':
          final alt = attrs['alt'] ?? '';
          final isEmoji = (attrs['itemtype'] ?? '').contains('Emoji') ||
              (alt.isNotEmpty && alt.runes.length <= 3);
          text(isEmoji ? alt : '[image]');
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
