import 'package:flutter/material.dart';

import '../../domain/entities/email.dart';
import 'email_date_formatter.dart';

class EmailListItem extends StatelessWidget {
  const EmailListItem({
    super.key,
    required this.email,
    required this.isSelected,
    required this.onTap,
  });

  final Email email;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF7C83FD).withAlpha(25)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: const Color(0xFF7C83FD).withAlpha(80))
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
                    color: Color(0xFF7C83FD),
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
                                ? const Color(0xFF9CA3AF)
                                : const Color(0xFFE0E0E0),
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
                              ? const Color(0xFF4B5563)
                              : const Color(0xFF7C83FD),
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
                                ? const Color(0xFF6B7280)
                                : const Color(0xFFD1D5DB),
                            fontSize: 12,
                            fontWeight: email.isRead
                                ? FontWeight.w400
                                : FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (email.hasAttachments)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.attach_file_rounded,
                            size: 12,
                            color: Color(0xFF4B5563),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    email.bodyPreview,
                    style: const TextStyle(
                      color: Color(0xFF4B5563),
                      fontSize: 11,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
