import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import 'email_date_formatter.dart';
import 'flag_icon_button.dart';

class EmailListItem extends StatelessWidget {
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
    this.onLongPress,
  });

  final Email email;
  final bool isSelected;
  final bool isMultiSelected;
  final bool showCheckbox;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onDelete;
  final void Function(DateTime? dueDate) onFlag;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final highlighted = isSelected || isMultiSelected;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: EdgeInsets.fromLTRB(8 + indent, 1, 8, 1),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: highlighted ? c.selectionEmailBg : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected ? Border.all(color: c.selectionBorder) : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: showCheckbox
                  ? Padding(
                      padding: const EdgeInsets.only(right: 8, top: 2),
                      child: Icon(
                        isMultiSelected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 18,
                        color: isMultiSelected ? AppColors.accent : c.textMuted,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            // Unread dot
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: AnimatedOpacity(
                opacity: email.isRead ? 0.0 : 1.0,
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
                          email.from.displayName,
                          style: TextStyle(
                            color: email.isRead
                                ? c.textTertiary
                                : c.textSecondary,
                            fontSize: 13,
                            fontWeight: email.isRead
                                ? FontWeight.w400
                                : FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatEmailDate(email.receivedDateTime),
                        style: TextStyle(
                          color: email.isRead
                              ? c.textDimmed
                              : AppColors.accent,
                          fontSize: 11,
                          fontWeight: email.isRead
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
                          email.subject,
                          style: TextStyle(
                            color: email.isRead
                                ? c.textMuted
                                : c.textBody,
                            fontSize: 12,
                            fontWeight: email.isRead
                                ? FontWeight.w400
                                : FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (email.hasAttachments)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.attach_file_rounded,
                            size: 12,
                            color: c.textDimmed,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    email.bodyPreview,
                    style: TextStyle(
                      color: c.textDimmed,
                      fontSize: 11,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FlagIconButton(
                  color: c.textDimmed,
                  onTap: () => onFlag(null),
                  onSchedule: (date) => onFlag(date),
                ),
                const SizedBox(height: 2),
                _ActionIcon(
                  icon: Icons.delete_outline_rounded,
                  color: c.textDimmed,
                  onTap: onDelete,
                ),
              ],
            ),
          ],
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
