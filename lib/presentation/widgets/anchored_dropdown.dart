import 'package:flutter/material.dart';

import '../../core/utils/dropdown_placement.dart';

/// A dropdown panel that hangs under an anchored field and stays inside the
/// window.
///
/// [CompositedTransformFollower] alone pins the panel's left edge to the
/// field's, and the fields that use this are `IntrinsicWidth` boxes sitting in
/// a `Wrap` after however many chips — so adding a recipient, guest or room
/// near the right of the window puts the caret there and the panel hung off
/// the edge, clipped. The correction is applied as the follower's [offset] so
/// the panel still tracks the field as it moves.
///
/// Anchoring the panel's *right* edge to the field's instead would not do it:
/// the target is the caret box, a few characters wide, not the row.
///
/// The surface measured is the [Overlay] the panel is drawn in, which is the
/// window rather than any dialog inside it. That is deliberate — the overlay is
/// what actually clips, and it is the coordinate space the target's position
/// has to be read in anyway.
class AnchoredDropdown extends StatelessWidget {
  const AnchoredDropdown({
    super.key,
    required this.link,
    required this.targetKey,
    required this.preferredWidth,
    required this.builder,
    this.onPointerDown,
  });

  /// Links to the [CompositedTransformTarget] wrapping the field.
  final LayerLink link;

  /// Key on that same target, used to measure where the field currently is.
  final GlobalKey targetKey;

  /// Width the panel is drawn at when there is room for it.
  final double preferredWidth;

  /// Builds the panel, given the width it may occupy.
  final Widget Function(BuildContext context, double maxWidth) builder;

  final VoidCallback? onPointerDown;

  @override
  Widget build(BuildContext context) {
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final targetBox = targetKey.currentContext?.findRenderObject() as RenderBox?;

    // Nothing measurable: draw where the follower alone would put it, at full
    // width. In practice this does not happen — the field has been laid out
    // since its own first frame, and the panel only opens once a search comes
    // back — so there is no frame of unshifted panel to see.
    var width = preferredWidth;
    var dx = 0.0;
    if (overlayBox != null &&
        overlayBox.hasSize &&
        targetBox != null &&
        targetBox.hasSize) {
      final surfaceWidth = overlayBox.size.width;
      width = dropdownWidthFor(
        preferredWidth: preferredWidth,
        surfaceWidth: surfaceWidth,
      );
      dx = dropdownHorizontalShift(
        targetLeft:
            targetBox.localToGlobal(Offset.zero, ancestor: overlayBox).dx,
        dropdownWidth: width,
        surfaceWidth: surfaceWidth,
      );
    }

    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: Offset(dx, 0),
        child: Listener(
          onPointerDown: onPointerDown == null ? null : (_) => onPointerDown!(),
          child: builder(context, width),
        ),
      ),
    );
  }
}
