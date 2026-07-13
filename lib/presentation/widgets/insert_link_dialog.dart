import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Prompts for a URL to insert as a link. Returns null on cancel, or an
/// empty/non-empty trimmed string on submit.
Future<String?> showInsertLinkDialog(BuildContext context) async {
  final urlController = TextEditingController();
  final url = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: context.colors.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      title: Text(
        'Insert Link',
        style: TextStyle(
          color: context.colors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: TextField(
        controller: urlController,
        autofocus: true,
        style: TextStyle(color: context.colors.textPrimary, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'https://example.com',
          hintStyle: TextStyle(color: context.colors.textMuted, fontSize: 13),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: TextStyle(color: context.colors.textMuted, fontSize: 13),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(urlController.text.trim()),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Insert', style: TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );
  urlController.dispose();
  return url;
}
