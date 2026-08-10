import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/linkify.dart';
import 'body_link_opener.dart';
import 'body_status_bar.dart';

/// A `text/plain` message body, with the URLs and addresses in it made
/// clickable.
///
/// The HTML path gets links for free — it hands a document to a webview, and
/// [linkifyHtml] only has to write the anchors. Here the body *is* the text, so
/// the links have to be spans, and that dictates the two choices below:
///
/// - **`SelectionArea` + `Text.rich`, not `SelectableText.rich`.**
///   `SelectableText` renders through `RenderEditable`, which never dispatches
///   to a span's `recognizer` — the links would look right and do nothing.
///   `Text.rich` inside a `SelectionArea` keeps the drag-to-select this body has
///   always had while letting the span handle the tap.
/// - **The status bar is this widget's, not the reading pane's.** It is the same
///   [BodyStatusBar] the webview path shows, so hovering a link in a plain text
///   message offers copy-link in the same place, with the same "stays until the
///   next link" behaviour (see [HoveredLinkChip]) — the bar is below the body,
///   so clearing on mouse-out would take the URL away mid-journey.
class PlainTextBodyView extends StatefulWidget {
  const PlainTextBodyView({
    super.key,
    required this.text,
    this.padding = const EdgeInsets.fromLTRB(28, 20, 28, 40),
  });

  final String text;

  /// Inset around the body. Defaults to the reading pane's.
  final EdgeInsets padding;

  @override
  State<PlainTextBodyView> createState() => _PlainTextBodyViewState();
}

class _PlainTextBodyViewState extends State<PlainTextBodyView> {
  List<LinkifiedRun> _runs = const [];

  /// One per run, non-null only for the link runs. Built with the runs rather
  /// than in `build`, so a rebuild (a hover, a theme change) does not dispose a
  /// recognizer that is in the middle of arbitrating a tap.
  List<TapGestureRecognizer?> _recognizers = const [];

  String? _hoveredLink;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(PlainTextBodyView old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _disposeRecognizers();
      _hoveredLink = null;
      _parse();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _parse() {
    _runs = linkifyPlainText(widget.text);
    _recognizers = [
      for (final run in _runs)
        if (run.isLink)
          TapGestureRecognizer()..onTap = () => _open(run.url!)
        else
          null,
    ];
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer?.dispose();
    }
    _recognizers = const [];
  }

  void _open(String url) {
    if (!mounted) return;
    unawaited(openBodyLink(context, url));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = TextStyle(color: c.textBody, fontSize: 14, height: 1.6);
    final linkStyle = base.copyWith(
      color: AppColors.accent,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.accent.withValues(alpha: 0.5),
    );

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: widget.padding,
            child: SelectionArea(
              child: Text.rich(
                TextSpan(
                  style: base,
                  children: [
                    for (var i = 0; i < _runs.length; i++)
                      if (_runs[i].isLink)
                        TextSpan(
                          text: _runs[i].text,
                          style: linkStyle,
                          mouseCursor: SystemMouseCursors.click,
                          recognizer: _recognizers[i],
                          onEnter: (_) => _onHover(_runs[i].url!),
                        )
                      else
                        TextSpan(text: _runs[i].text),
                  ],
                ),
              ),
            ),
          ),
        ),
        BodyStatusBar(hoveredLink: _hoveredLink),
      ],
    );
  }

  void _onHover(String url) {
    if (url == _hoveredLink || !mounted) return;
    setState(() => _hoveredLink = url);
  }
}
