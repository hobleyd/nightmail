import 'package:flutter/material.dart';

import '../../core/platform/touch_metrics.dart';
import '../../core/theme/app_colors.dart';

/// What the user picked from a [ReportJunkButton]'s menu.
enum ReportJunkAction { junk, phishing }

/// The Report-junk toolbar button, in the three shapes it takes.
///
/// On a desktop, outside the Junk folder, it is a **dropdown**: a click opens
/// a menu under the icon offering *Report junk* and *Report phishing*, the
/// split Outlook's own Report button makes. The caret beside the icon is what
/// says so — without it the button looks like every other one-shot icon in
/// the row.
///
/// In the **Junk folder** the only sensible action is the reverse, so it is a
/// plain *Not junk* tap, as it was before the menu existed. Reporting phishing
/// from inside Junk is deliberately not offered: the list handler removes the
/// row on the assumption the message is leaving the folder, and here it would
/// not be.
///
/// On a **touch screen** it is a plain *Report junk* tap. The menu is a
/// desktop affordance; the list's swipe actions are the touch one.
class ReportJunkButton extends StatelessWidget {
  const ReportJunkButton({
    super.key,
    required this.isJunkFolder,
    required this.onReportJunk,
    required this.onReportPhishing,
    required this.onNotJunk,
    this.color,
    this.iconSize = 20,
    this.targetSize = 32,
  });

  /// Whether the folder on screen is Junk itself, which turns the button into
  /// *Not junk*.
  final bool isJunkFolder;
  final VoidCallback onReportJunk;
  final VoidCallback onReportPhishing;
  final VoidCallback onNotJunk;
  final Color? color;

  /// The glyph size as the desktop layout asked for; doubled on touch.
  final double iconSize;

  /// The tap target as the desktop layout asked for; see [touchTarget].
  final double targetSize;

  /// Whether a click opens the menu rather than acting at once.
  bool get _showsMenu => !isJunkFolder && !isTouchPlatform;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      isJunkFolder ? Icons.report_off_outlined : Icons.report_outlined,
      size: touchIcon(iconSize),
      color: color,
    );
    if (!_showsMenu) {
      return IconButton(
        icon: glyph,
        tooltip: isJunkFolder ? 'Not junk' : 'Report junk',
        padding: EdgeInsets.zero,
        constraints: BoxConstraints(
          minWidth: touchTarget(targetSize),
          minHeight: touchTarget(targetSize),
        ),
        onPressed: isJunkFolder ? onNotJunk : onReportJunk,
      );
    }
    return Builder(
      // Its own element, so the menu can be anchored to this button's render
      // box rather than to whatever the parent happens to be.
      builder: (buttonContext) => IconButton(
        icon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            glyph,
            Icon(Icons.arrow_drop_down, size: touchIcon(14), color: color),
          ],
        ),
        tooltip: 'Report junk or phishing',
        padding: EdgeInsets.zero,
        constraints: BoxConstraints(
          minWidth: touchTarget(targetSize),
          minHeight: touchTarget(targetSize),
        ),
        onPressed: () => _showMenu(buttonContext),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context) async {
    final button = context.findRenderObject() as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    // Anchored along the button's bottom edge, so the menu drops down from it
    // the way a dropdown's does rather than opening at the pointer.
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset(0, button.size.height), ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    final chosen = await showMenu<ReportJunkAction>(
      context: context,
      position: position,
      items: const [
        PopupMenuItem(
          value: ReportJunkAction.junk,
          child: _MenuRow(icon: Icons.report_outlined, label: 'Report junk'),
        ),
        PopupMenuItem(
          value: ReportJunkAction.phishing,
          child: _MenuRow(icon: Icons.phishing, label: 'Report phishing'),
        ),
      ],
    );
    switch (chosen) {
      case ReportJunkAction.junk:
        onReportJunk();
      case ReportJunkAction.phishing:
        onReportPhishing();
      case null:
        break;
    }
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Icon(icon, size: 16, color: c.textMuted),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 13, color: c.textPrimary)),
      ],
    );
  }
}
