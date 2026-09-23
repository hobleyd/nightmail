import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// An alert that takes the iOS look on an iPhone or iPad and stays a Material
/// [AlertDialog] everywhere else — macOS included, where the app's own dialog
/// styling is the desktop look and a system alert would be a regression.
///
/// Deliberately not [AlertDialog.adaptive]: that switches on
/// `Theme.of(context).platform`, which is macOS on a Mac.
///
/// The Cupertino form is only used when the dialog is a plain alert: a text
/// title, a text body (or none) and text-button actions. Anything with a form
/// or a list in it keeps the Material dialog on iOS too, because a Cupertino
/// alert has no room for controls. So every site can use this unchanged, and
/// the ones that qualify become native alerts on the phone.
class AdaptiveAlertDialog extends StatelessWidget {
  const AdaptiveAlertDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.backgroundColor,
    this.shape,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Color? backgroundColor;
  final ShapeBorder? shape;

  static bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  /// Words an action label carries when it destroys something, so the
  /// Cupertino action is drawn in red like the Material one was.
  static final _destructiveWords = RegExp(
    r'\b(delete|remove|discard|empty|decline|cancel meeting|sign out|'
    r'unsubscribe|clear)\b',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    if (_isIOS) {
      final cupertino = _tryCupertino();
      if (cupertino != null) return cupertino;
    }
    return AlertDialog(
      title: title,
      content: content,
      actions: actions,
      backgroundColor: backgroundColor,
      shape: shape,
    );
  }

  Widget? _tryCupertino() {
    final actions = this.actions;
    if (actions == null || actions.isEmpty) return null;
    if (!_isPlainText(content)) return null;
    final cupertinoActions = <Widget>[];
    for (final action in actions) {
      final converted = _convertAction(action, isLast: action == actions.last);
      if (converted == null) return null;
      cupertinoActions.add(converted);
    }
    return CupertinoAlertDialog(
      title: title,
      content: content == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 8),
              child: content,
            ),
      actions: cupertinoActions,
    );
  }

  static bool _isPlainText(Widget? content) {
    if (content == null || content is Text) return true;
    if (content is SingleChildScrollView) return content.child is Text;
    return false;
  }

  /// A Material text/filled button with a text label, as a Cupertino action;
  /// null for anything else, which sends the whole dialog back to Material.
  static Widget? _convertAction(Widget action, {required bool isLast}) {
    if (action is! ButtonStyleButton) return null;
    final child = action.child;
    if (child is! Text || child.data == null) return null;
    final label = child.data!;
    final background = action.style?.backgroundColor?.resolve(const {});
    final destructive = _looksRed(background) ||
        _looksRed(child.style?.color) ||
        _destructiveWords.hasMatch(label);
    // A filled button was the primary action; failing one, the last.
    final isDefault = action is FilledButton ||
        action is ElevatedButton ||
        (isLast && !destructive);
    return CupertinoDialogAction(
      onPressed: action.onPressed,
      isDestructiveAction: destructive,
      isDefaultAction: isDefault,
      child: Text(label),
    );
  }

  static bool _looksRed(Color? c) =>
      c != null && c.r > 0.6 && c.g < 0.45 && c.b < 0.45;
}
