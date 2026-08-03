import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// Shows the URL the pointer is over in the message body, and copies it on
/// click.
///
/// It sits in the reading pane's toolbar rather than beside the cursor because
/// the body is a native webview layered *over* the Flutter surface — no Flutter
/// widget can be drawn on top of it (the same reason
/// `HtmlViewController.setVisible` exists for dialogs). The in-page CSS status
/// bar in `html_body_view.dart` still shows the URL under the pointer; this is
/// the copy of it you can click.
///
/// [url] deliberately persists after the pointer leaves the link — the walk up
/// to the toolbar crosses non-link content, and clearing on mouse-out would
/// take the URL away before the user arrived. It is replaced by the next link
/// hovered and reset when the open email changes.
class HoveredLinkChip extends StatefulWidget {
  const HoveredLinkChip({super.key, required this.url});

  final String url;

  @override
  State<HoveredLinkChip> createState() => _HoveredLinkChipState();
}

class _HoveredLinkChipState extends State<HoveredLinkChip> {
  bool _hovering = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Link copied to clipboard'),
        duration: Duration(milliseconds: 1200),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // The URL is already on screen, so the tooltip is mainly there to say what
    // the click does; it repeats the URL only to show it un-ellipsised.
    return Tooltip(
      message: 'Copy link\n${widget.url}',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: _copy,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _hovering ? AppColors.accent.withAlpha(40) : c.logoContainerBg,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: _hovering ? c.selectionBorder : c.border,
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link_rounded, size: 13, color: c.textMuted),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    widget.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _hovering ? c.textSecondary : c.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.copy_rounded, size: 12, color: c.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
