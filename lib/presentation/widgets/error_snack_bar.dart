import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Long enough to count as "until dismissed". [SnackBar] has no indefinite
/// duration, so this is the idiom: a value the user will never outlast.
const Duration _untilDismissed = Duration(days: 1);

/// Shows an error that stays on screen until it is dismissed, with a copy
/// button that puts the full message on the clipboard and closes the snack bar.
///
/// Error text is the one thing in the app worth reading twice — server
/// handshake/protocol failures in particular are long, wrap to several lines,
/// and are only useful if they can be pasted somewhere. The default four-second
/// snack bar is not enough time to read one, let alone copy it, so this one
/// persists and offers both a copy and a close affordance.
///
/// [copyText] defaults to [message]; pass it when the clipboard should carry
/// more detail than the visible text.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showErrorSnackBar(
  BuildContext context,
  String message, {
  String? copyText,
}) {
  final messenger = ScaffoldMessenger.of(context);

  // A persistent snack bar would otherwise dam the queue: anything shown after
  // it waits for it to close, which now never happens on its own.
  messenger.clearSnackBars();

  late final ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
      controller;
  controller = messenger.showSnackBar(
    SnackBar(
      backgroundColor: Colors.red.shade700,
      duration: _untilDismissed,
      showCloseIcon: true,
      closeIconColor: Colors.white,
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(message)),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            color: Colors.white,
            tooltip: 'Copy error',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: copyText ?? message));
              controller.close();
            },
          ),
        ],
      ),
    ),
  );

  return controller;
}
