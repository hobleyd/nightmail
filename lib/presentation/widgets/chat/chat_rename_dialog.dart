import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/chat.dart';
import '../adaptive_alert_dialog.dart';

/// Asks for a new name for [conversation] and hands it to [rename], which
/// answers null once it is renamed or why not — shown under the field, with
/// the dialog left open to try again. True when it was renamed.
Future<bool> showChatRenameDialog(
  BuildContext context, {
  required ChatConversation conversation,
  required Future<String?> Function(String title) rename,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) =>
          _ChatRenameDialog(conversation: conversation, rename: rename),
    ) ??
    false;

class _ChatRenameDialog extends StatefulWidget {
  const _ChatRenameDialog({required this.conversation, required this.rename});

  final ChatConversation conversation;
  final Future<String?> Function(String title) rename;

  @override
  State<_ChatRenameDialog> createState() => _ChatRenameDialogState();
}

class _ChatRenameDialogState extends State<_ChatRenameDialog> {
  late final TextEditingController _name;

  /// What the field opened with.
  late final String _initial;
  bool _saving = false;
  String? _error;

  /// A Slack channel is titled `#name`; the `#` is not part of its name.
  bool get _slackChannel =>
      widget.conversation.kind == ChatKind.space &&
      widget.conversation.title.startsWith('#');

  @override
  void initState() {
    super.initState();
    final title = widget.conversation.title;
    _initial = _slackChannel ? title.substring(1) : title;
    _name = TextEditingController(text: _initial)
      ..selection =
          TextSelection(baseOffset: 0, extentOffset: _initial.length);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (_saving || name.isEmpty) return;
    // The name it already has is not sent: a group chat without a topic is
    // titled by its members, and saving that would fix it as the topic and
    // tell everyone in it the chat was renamed. Slack lowercases a name and
    // hyphenates its spaces, so "General" is still #general.
    final same = _slackChannel
        ? name.toLowerCase().replaceAll(RegExp(r'\s+'), '-') == _initial
        : name == _initial;
    if (same) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.rename(name);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final channel = widget.conversation.isChannel || _slackChannel;
    return AdaptiveAlertDialog(
      title: Text(channel ? 'Rename channel' : 'Rename chat'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              enabled: !_saving,
              decoration: InputDecoration(
                labelText: 'Name',
                prefixText: _slackChannel ? '#' : null,
                helperText: _slackChannel
                    ? 'Lowercase, with hyphens for spaces, as Slack names it.'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: TextStyle(fontSize: 12, color: c.errorBannerText)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              _saving || _name.text.trim().isEmpty ? null : () => _save(),
          child: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Rename'),
        ),
      ],
    );
  }
}
