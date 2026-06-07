import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import 'email_date_formatter.dart';

class EmailListItem extends StatelessWidget {
  const EmailListItem({
    super.key,
    required this.email,
    required this.isSelected,
    required this.onTap,
    required this.onDelete,
    required this.onFlag,
    this.indent = 0.0,
  });

  final Email email;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onFlag;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: EdgeInsets.fromLTRB(8 + indent, 1, 8, 1),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? c.selectionEmailBg : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: c.selectionBorder)
              : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                _ActionIcon(
                  icon: Icons.delete_outline_rounded,
                  color: c.textDimmed,
                  onTap: onDelete,
                ),
                const SizedBox(height: 2),
                _ActionIcon(
                  icon: Icons.flag_outlined,
                  color: c.textDimmed,
                  onTap: onFlag,
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
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 15, color: color),
      ),
    );
  }
}
