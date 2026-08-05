import 'package:flutter/foundation.dart';

/// Whether the UI is being driven by a fingertip rather than a mouse pointer.
///
/// Read through [defaultTargetPlatform] rather than `Platform.isAndroid` so a
/// widget test can drive it with `debugDefaultTargetPlatformOverride`.
///
/// This is deliberately about the *input device*, not the layout width: the
/// three-panel desktop layout collapses to the single-pane mobile one below
/// 600 px, but a narrow window on a desktop is still driven by a mouse and
/// keeps the compact metrics it was designed around.
bool get isTouchPlatform =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// The flat tap target used on a touch screen — Material's and HIG's minimum,
/// and enough to sit a doubled glyph inside with room to spare.
const double kTouchTargetSize = 48.0;

/// [size] on desktop, doubled on a touch screen.
///
/// Every icon in this app is drawn at 12–20 px, which is precise with a pointer
/// and a poor target for a fingertip. Mobile draws them at twice the size.
double touchIcon(double size) => isTouchPlatform ? size * 2 : size;

/// The tap target around an icon: [size] as the desktop layout asked for, a
/// flat [kTouchTargetSize] on a touch screen.
///
/// Deliberately *not* doubled the way the glyph is. The list header carries up
/// to six of these in one row; doubling the compact 24–32 px desktop boxes
/// would need 384 px of toolbar and overflow every phone narrower than a
/// Pixel. 48 px clears both platforms' minimum-target guidance, fits six
/// across a 320 pt screen, and still frames a doubled glyph.
double touchTarget(double size) => isTouchPlatform ? kTouchTargetSize : size;

/// A toolbar/header row height, grown to fit a [kTouchTargetSize] button.
double touchRowHeight(double height) =>
    isTouchPlatform && height < kTouchTargetSize ? kTouchTargetSize : height;
