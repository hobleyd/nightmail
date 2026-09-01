import 'package:flutter/material.dart';

import '../../core/platform/touch_metrics.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import 'email_date_formatter.dart';
import 'email_folder_label.dart';
import 'flag_icon_button.dart';

class EmailListItem extends StatefulWidget {
  const EmailListItem({
    super.key,
    required this.email,
    required this.isSelected,
    required this.onTap,
    required this.onDelete,
    required this.onFlag,
    this.indent = 0.0,
    this.isMultiSelected = false,
    this.showCheckbox = false,
    this.isSpam = false,
    this.isDesktop = true,
    this.isDuplicate = false,
    this.folderLabel,
    this.onLongPress,
    this.onDoubleTap,
    this.flagFocusNode,
    this.deleteFocusNode,
  });

  final Email email;
  final bool isSelected;
  final bool isMultiSelected;
  final bool showCheckbox;
  final bool isSpam;
  final bool isDesktop;

  /// True when this row repeats a message already shown by the thread header
  /// above it. Drawn in italics to say so, and without the hover actions — they
  /// belong to the row this one echoes.
  final bool isDuplicate;

  /// The folder this message lives in, drawn in brackets between the sender and
  /// the date. Null when it could not be resolved to a real folder name — see
  /// [emailFolderLabel].
  final String? folderLabel;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final VoidCallback onDelete;
  final void Function(DateTime? dueDate) onFlag;
  final double indent;
  final FocusNode? flagFocusNode;
  final FocusNode? deleteFocusNode;

  @override
  State<EmailListItem> createState() => _EmailListItemState();
}

class _EmailListItemState extends State<EmailListItem> {
  bool _isHovered = false;
  late final FocusNode _localFlagFn = FocusNode(skipTraversal: true);
  late final FocusNode _localDeleteFn = FocusNode(skipTraversal: true);

  @override
  void dispose() {
    _localFlagFn.dispose();
    _localDeleteFn.dispose();
    super.dispose();
  }

  // When the from address is empty (e.g. unsent drafts from Graph API), fall
  // back to showing the recipients so the Drafts list is useful.
  static String _senderLabel(Email email) {
    if (email.from.address.isNotEmpty) return email.from.displayName;
    final recipients = email.toRecipients;
    if (recipients.isEmpty) return '';
    final names = recipients.take(2).map((r) => r.displayName).join(', ');
    return 'To: $names${recipients.length > 2 ? '…' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final highlighted = widget.isSelected || widget.isMultiSelected;
    final fontStyle = widget.isDuplicate ? FontStyle.italic : null;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: EdgeInsets.fromLTRB(8 + widget.indent, 1, 8, 1),
          // Left padding tracks the conversation row's chevron gutter so the
          // two stay pixel-aligned — see _ConversationHeader.
          padding: EdgeInsets.fromLTRB(touchIcon(12), 8, 12, 8),
          decoration: BoxDecoration(
            color: highlighted
                ? c.selectionEmailBg
                : _isHovered
                    ? c.hoverEmailBg
                    : widget.isSpam
                        ? Colors.pink.shade100.withAlpha(60)
                        : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: widget.isSelected ? Border.all(color: c.selectionBorder) : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: widget.showCheckbox
                    ? Padding(
                        padding: const EdgeInsets.only(right: 8, top: 2),
                        child: Icon(
                          widget.isMultiSelected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: touchIcon(18),
                          color: widget.isMultiSelected ? AppColors.accent : c.textMuted,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              // Unread dot
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: AnimatedOpacity(
                  opacity: widget.email.isRead ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 300),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: AppColors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A LayoutBuilder because the folder label's cap is a
                    // fraction of the row (see [folderLabelMaxWidth]), and an
                    // inflexible child of a Row is measured against an
                    // unbounded width, so it cannot work that out for itself.
                    LayoutBuilder(builder: (context, constraints) {
                      return Row(
                        children: [
                          Expanded(
                            child: Text(
                              _senderLabel(widget.email),
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 13,
                                fontStyle: fontStyle,
                                fontWeight: widget.email.isRead
                                    ? FontWeight.w400
                                    : FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (widget.folderLabel != null) ...[
                            const SizedBox(width: 6),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                  maxWidth:
                                      folderLabelMaxWidth(constraints.maxWidth)),
                              child: Text(
                                '[${widget.folderLabel}]',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.textTertiary,
                                  fontSize: 11,
                                  fontStyle: fontStyle,
                                  fontWeight: widget.email.isRead
                                      ? FontWeight.w400
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(width: 8),
                          Text(
                            formatEmailDate(widget.email.receivedDateTime),
                            style: TextStyle(
                              color: c.textTertiary,
                              fontSize: 11,
                              fontStyle: fontStyle,
                              fontWeight: widget.email.isRead
                                  ? FontWeight.w400
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      );
                    }),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.email.subject,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 12,
                              fontStyle: fontStyle,
                              fontWeight: widget.email.isRead
                                  ? FontWeight.w400
                                  : FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // The provider's own flag — Graph's follow-up flag,
                        // Gmail's star, IMAP's `\Flagged` — set on this or any
                        // other client. Read-only here on purpose: NightMail's
                        // flag *button* creates a follow-up task, which is a
                        // different thing, so this must not look like a control.
                        if (widget.email.isFlagged)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.star_rounded,
                              size: touchIcon(13),
                              color: AppColors.accent,
                            ),
                          ),
                        if (widget.email.hasAttachments)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.attach_file_rounded,
                              size: touchIcon(12),
                              color: c.textMuted,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.email.bodyPreview,
                      style: TextStyle(
                        color: c.textTertiary,
                        fontSize: 11,
                        fontStyle: fontStyle,
                        height: 1.3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (widget.isDesktop && !widget.isDuplicate) ...[
                const SizedBox(width: 4),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FlagIconButton(
                      focusNode: widget.flagFocusNode ?? _localFlagFn,
                      color: c.textMuted,
                      onTap: () => widget.onFlag(null),
                      onSchedule: (date) => widget.onFlag(date),
                    ),
                    const SizedBox(height: 2),
                    _ActionIcon(
                      icon: Icons.delete_outline_rounded,
                      color: c.textMuted,
                      focusNode: widget.deleteFocusNode ?? _localDeleteFn,
                      onTap: widget.onDelete,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.color,
    required this.onTap,
    this.focusNode,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      focusNode: focusNode,
      icon: Icon(icon, size: 15, color: color),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: onTap,
    );
  }
}
