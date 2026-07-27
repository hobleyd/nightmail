import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Prompts for a URL to insert as a link. Returns null on cancel, or an
/// empty/non-empty trimmed string on submit.
Future<String?> showInsertLinkDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _InsertLinkDialog(),
  );
}

/// Stateful so the controller's lifetime is the dialog's own.
///
/// Disposing it right after `showDialog` resolves is too early: the future
/// completes on `pop`, while the route keeps rebuilding its subtree through the
/// dismissal animation, and the [TextField] then reattaches to a dead
/// controller.
class _InsertLinkDialog extends StatefulWidget {
  const _InsertLinkDialog();

  @override
  State<_InsertLinkDialog> createState() => _InsertLinkDialogState();
}

class _InsertLinkDialogState extends State<_InsertLinkDialog> {
  final _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_urlController.text.trim());

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      title: Text(
        'Insert Link',
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: TextField(
        controller: _urlController,
        autofocus: true,
        style: TextStyle(color: c.textPrimary, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'https://example.com',
          hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: TextStyle(color: c.textMuted, fontSize: 13),
          ),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Insert', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}
