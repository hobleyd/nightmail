import 'dart:math' as math;

/// Horizontal gap kept between a dropdown panel and the edge of the surface it
/// is drawn on.
const double kDropdownEdgeInset = 8;

/// How wide a dropdown panel anchored under a field may be drawn.
///
/// A panel is otherwise its own fixed width, which is wider than the window in
/// the narrow case — so the preferred width is only ever a maximum.
double dropdownWidthFor({
  required double preferredWidth,
  required double surfaceWidth,
  double inset = kDropdownEdgeInset,
}) {
  final available = surfaceWidth - inset * 2;
  if (available <= 0) return preferredWidth;
  return math.min(preferredWidth, available);
}

/// How far left a dropdown anchored to a field's left edge has to move to stay
/// inside the surface it is drawn on. Never positive unless the field itself
/// starts inside the left inset, in which case the panel is nudged right so the
/// near edge stays visible.
///
/// [targetLeft] and [surfaceWidth] must be in the same coordinate space — the
/// overlay's, in practice, which is what `localToGlobal(ancestor:)` gives.
double dropdownHorizontalShift({
  required double targetLeft,
  required double dropdownWidth,
  required double surfaceWidth,
  double inset = kDropdownEdgeInset,
}) {
  final overflow = targetLeft + dropdownWidth - (surfaceWidth - inset);
  if (overflow <= 0 && targetLeft >= inset) return 0;
  return math.max(-overflow, inset - targetLeft);
}
