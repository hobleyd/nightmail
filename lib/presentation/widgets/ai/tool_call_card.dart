import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/usecases/ai/agent/email_agent_tools.dart';
import '../../blocs/ai/ai_folder_chat_state.dart';
import '../../blocs/email_list/email_list_event.dart' show EmailListResultSet;

/// The emails a finished `search_emails` / `list_emails` call found, or a
/// `show_emails` call picked out, as a set the email list can re-run — or null
/// for any other tool, a call still running or failed, or one that found
/// nothing. Uses the tools' own limits, so the replay asks the same question.
EmailListResultSet? agentEmailResults(AiToolItem item) {
  if (item.status != AiToolStatus.complete) return null;
  final found = _resultCount(item);
  if (found == null || found == 0) return null;

  final args = item.args;
  final folderId = _argString(args['folder_id']) ?? item.turnFolderId;
  switch (item.name) {
    case 'show_emails':
      // The ids that were read back, not the ones asked for: one the model
      // made up is in `notFound`, not `emails`.
      final ids = _resultIds(item);
      if (ids.isEmpty) return null;
      return EmailListResultSet(
        title: _argString(args['title']) ?? 'Picked emails',
        accountId: item.turnAccountId,
        ids: ids,
      );
    case 'search_emails':
      final query = _argString(args['query']);
      if (query == null) return null;
      return EmailListResultSet(
        title: query,
        accountId: item.turnAccountId,
        query: query,
        folderId: folderId,
        top: (_argInt(args['limit']) ?? SearchEmailsTool.defaultLimit)
            .clamp(1, SearchEmailsTool.maxLimit),
      );
    case 'list_emails':
      final unreadOnly = args['unread_only'] == true ||
          '${args['unread_only']}'.toLowerCase() == 'true';
      return EmailListResultSet(
        title: unreadOnly ? 'Unread emails' : 'Latest emails',
        accountId: item.turnAccountId,
        folderId: folderId,
        top: (_argInt(args['limit']) ?? ListEmailsTool.defaultLimit)
            .clamp(1, ListEmailsTool.maxLimit),
        unreadOnly: unreadOnly,
      );
  }
  return null;
}

/// The `count` an email-list tool reported, or null when the output is not one.
int? _resultCount(AiToolItem item) {
  final out = item.output;
  if (out == null) return null;
  try {
    final decoded = jsonDecode(out);
    return decoded is Map<String, dynamic> && decoded['emails'] is List
        ? (decoded['emails'] as List).length
        : null;
  } on FormatException {
    return null;
  }
}

/// The ids in an email-list tool's output.
List<String> _resultIds(AiToolItem item) {
  try {
    final decoded = jsonDecode(item.output ?? '');
    final emails = decoded is Map<String, dynamic> ? decoded['emails'] : null;
    return [
      if (emails is List)
        for (final e in emails)
          if (e is Map && e['id'] is String) e['id'] as String,
    ];
  } on FormatException {
    return const [];
  }
}

String? _argString(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _argInt(Object? v) => switch (v) {
      int() => v,
      double() => v.toInt(),
      String() => int.tryParse(v),
      _ => null,
    };

/// An inline, collapsible card rendering a single agent tool call — the Vercel
/// AI Elements `Tool` pattern adapted to Flutter.
///
/// Collapsed (default) is a compact one-liner: tool icon, humanized name, a
/// short argument preview, a status pill, and a chevron. Tapping expands to show
/// pretty-printed JSON for the input arguments and the output (or error text).
/// An [AiToolStatus.error] card is forced open and cannot be collapsed.
///
/// A finished email search or listing also offers to show what it found in the
/// email list ([onShowInList]); a host without a list passes null.
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.item, this.onShowInList});

  final AiToolItem item;
  final ValueChanged<EmailListResultSet>? onShowInList;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  /// Success-state glyph color (no green in [AppColors], so use a local one).
  static const Color _successColor = Color(0xFF34D399);

  bool _expanded = false;

  bool get _forceExpanded => widget.item.status == AiToolStatus.error;
  bool get _isExpanded => _expanded || _forceExpanded;

  void _toggle() {
    if (_forceExpanded) return;
    setState(() => _expanded = !_expanded);
  }

  /// Humanized tool name, tensed by lifecycle status.
  String _humanizedName() {
    final running = widget.item.status == AiToolStatus.running;
    switch (widget.item.name) {
      case 'search_emails':
        return running ? 'Searching…' : 'Searched emails';
      case 'list_emails':
        return running ? 'Listing…' : 'Listed emails';
      case 'get_email':
        return running ? 'Reading…' : 'Read email';
      case 'list_folders':
        return running ? 'Listing…' : 'Listed folders';
      case 'check_email_safety':
        return running ? 'Checking…' : 'Checked security signals';
      case 'show_emails':
        return running ? 'Picking out…' : 'Picked out emails';
      default:
        return widget.item.name;
    }
  }

  IconData _toolIcon() {
    switch (widget.item.name) {
      case 'search_emails':
        return Icons.search;
      case 'list_emails':
        return Icons.list_alt_outlined;
      case 'get_email':
        return Icons.mail_outline;
      case 'list_folders':
        return Icons.folder_outlined;
      case 'check_email_safety':
        return Icons.shield_outlined;
      case 'show_emails':
        return Icons.checklist_rtl;
      default:
        return Icons.build_outlined;
    }
  }

  /// The first salient argument value (e.g. the search query, an email id, or a
  /// subject) for the collapsed one-liner preview, or null when none.
  String? _argPreview() {
    final args = widget.item.args;
    for (final key in const ['query', 'title', 'subject', 'id', 'folder_id']) {
      final v = args[key];
      final s = v?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    if (args.isNotEmpty) {
      final s = args.values.first?.toString().trim();
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  String _prettyArgs() {
    try {
      return _encoder.convert(widget.item.args);
    } catch (_) {
      return widget.item.args.toString();
    }
  }

  /// Pretty-prints [AiToolItem.output]: when it is a JSON string, decode then
  /// re-encode indented; otherwise fall back to the raw string.
  String _prettyOutput() {
    final out = widget.item.output;
    if (out == null || out.isEmpty) return '';
    try {
      return _encoder.convert(jsonDecode(out));
    } on FormatException {
      return out;
    } catch (_) {
      return out;
    }
  }

  Widget _statusPill(AppColors c) {
    switch (widget.item.status) {
      case AiToolStatus.running:
        return const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
          ),
        );
      case AiToolStatus.complete:
        return const Icon(
          Icons.check_circle_outline,
          size: 15,
          color: _successColor,
        );
      case AiToolStatus.error:
        return Icon(
          Icons.error_outline,
          size: 15,
          color: c.errorBannerText,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Container(
        decoration: BoxDecoration(
          color: c.surfacePanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.separatorStrong),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(c),
            if (_isExpanded) _buildBody(c),
            _buildShowInList(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    final preview = _argPreview();
    final chevron = _isExpanded
        ? Icons.keyboard_arrow_up_rounded
        : Icons.keyboard_arrow_down_rounded;
    return InkWell(
      onTap: _forceExpanded ? null : _toggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(_toolIcon(), size: 14, color: c.textMuted),
            const SizedBox(width: 8),
            Text(
              _humanizedName(),
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (preview != null) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 8),
            _statusPill(c),
            const SizedBox(width: 4),
            Icon(chevron, size: 16, color: c.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildShowInList() {
    final onShow = widget.onShowInList;
    final results = onShow == null ? null : agentEmailResults(widget.item);
    if (results == null) return const SizedBox.shrink();
    final n = _resultCount(widget.item)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
      child: TextButton.icon(
        onPressed: () => onShow!(results),
        icon: const Icon(Icons.view_list_outlined, size: 15),
        label: Text(
          'Show $n ${n == 1 ? 'email' : 'emails'} in list',
          style: const TextStyle(fontSize: 12),
        ),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.accent,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  Widget _buildBody(AppColors c) {
    final output = _prettyOutput();
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(c, 'Input'),
          _codeBlock(c, _prettyArgs()),
          const SizedBox(height: 8),
          _sectionLabel(c, 'Output'),
          _codeBlock(c, output.isEmpty ? '—' : output),
        ],
      ),
    );
  }

  Widget _sectionLabel(AppColors c, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: c.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _codeBlock(AppColors c, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          text,
          style: TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
            fontSize: 11,
            height: 1.4,
            color: c.textSecondary,
          ),
        ),
      ),
    );
  }
}
