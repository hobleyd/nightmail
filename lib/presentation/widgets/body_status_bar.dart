import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'hovered_link_chip.dart';

/// The strip under a rendered message body. It carries the link the pointer is
/// over (with a copy button) and, when the sender's remote images were held
/// back, the buttons to fetch them.
///
/// Both share one strip rather than stacking two: the hovered link and the
/// image notice would otherwise sit in adjacent 29px bars saying different
/// things. With a link showing, the "External images blocked" wording drops to
/// its icon — the two buttons stay put, because hiding them would strand a
/// decision the reader still has to make (the link persists for the whole
/// message, so they would never come back).
///
/// Renders nothing at all when there is neither, so the body keeps its full
/// height on a message with no blocked images until the first link is hovered.
class BodyStatusBar extends StatelessWidget {
  const BodyStatusBar({
    super.key,
    this.hoveredLink,
    this.imagesBlocked = false,
    this.onDownloadOnce,
    this.onAlwaysDownload,
  });

  /// URL of the link under the pointer, or null if none has been hovered.
  final String? hoveredLink;

  /// Whether this message has remote images that were not downloaded.
  /// [onDownloadOnce] and [onAlwaysDownload] are required when it is true.
  final bool imagesBlocked;

  final VoidCallback? onDownloadOnce;
  final VoidCallback? onAlwaysDownload;

  static const double height = 29;

  /// Narrower than this, the two image buttons leave no legible room for a URL
  /// beside them (they and the padding claim ~250px on their own), so the link
  /// gives way — the reader can widen the pane, and squeezing both in is what
  /// overflows the strip. The reading pane can be dragged down to 200px.
  static const double _widthForBoth = 420;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final link = hoveredLink;
    if (link == null && !imagesBlocked) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final showLink = link != null &&
            (!imagesBlocked || constraints.maxWidth >= _widthForBoth);

        return Container(
          height: height,
          decoration: BoxDecoration(
            color: c.surfacePanel,
            border: Border(top: BorderSide(color: c.border, width: 1)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (showLink)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: HoveredLinkChip(url: link),
                  ),
                ),
              if (imagesBlocked) ...[
                Tooltip(
                  message: 'External images blocked',
                  child: Icon(Icons.hide_image_outlined,
                      size: 13, color: c.textMuted),
                ),
                if (!showLink) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'External images blocked',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
                  ),
                  const Spacer(),
                ] else
                  const SizedBox(width: 8),
                _StatusBarButton(
                  label: 'Download once',
                  onPressed: onDownloadOnce!,
                ),
                const SizedBox(width: 4),
                _StatusBarButton(
                  label: 'Always download',
                  onPressed: onAlwaysDownload!,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _StatusBarButton extends StatefulWidget {
  const _StatusBarButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  State<_StatusBarButton> createState() => _StatusBarButtonState();
}

class _StatusBarButtonState extends State<_StatusBarButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: widget.onPressed,
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 70),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _isPressed
                ? AppColors.accent.withAlpha(70)
                : AppColors.accent.withAlpha(30),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: AppColors.accent.withAlpha(80), width: 0.5),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: c.textTertiary,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}
