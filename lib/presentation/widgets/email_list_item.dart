import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import 'email_date_formatter.dart';
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
    this.onLongPress,
    this.onDoubleTap,
  });

  final Email email;
  final bool isSelected;
  final bool isMultiSelected;
  final bool showCheckbox;
  final bool isSpam;
  final bool isDesktop;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final VoidCallback onDelete;
  final void Function(DateTime? dueDate) onFlag;
  final double indent;

  @override
  State<EmailListItem> createState() => _EmailListItemState();
}

class _EmailListItemState extends State<EmailListItem> {
  bool _isHovered = false;

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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                          size: 18,
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
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _senderLabel(widget.email),
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 13,
                              fontWeight: widget.email.isRead
                                  ? FontWeight.w400
                                  : FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatEmailDate(widget.email.receivedDateTime),
                          style: TextStyle(
                            color: c.textTertiary,
                            fontSize: 11,
                            fontWeight: widget.email.isRead
                                ? FontWeight.w400
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.email.subject,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 12,
                              fontWeight: widget.email.isRead
                                  ? FontWeight.w400
                                  : FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.email.hasAttachments)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.attach_file_rounded,
                              size: 12,
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
                        height: 1.3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (widget.isDesktop) ...[
                const SizedBox(width: 4),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FlagIconButton(
                      color: c.textMuted,
                      onTap: () => widget.onFlag(null),
                      onSchedule: (date) => widget.onFlag(date),
                    ),
                    const SizedBox(height: 2),
                    _ActionIcon(
                      icon: Icons.delete_outline_rounded,
                      color: c.textMuted,
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
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 15, color: color),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: onTap,
    );
  }
}
