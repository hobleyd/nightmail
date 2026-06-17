import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_selector/file_selector.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as wvw;

import '../../core/settings/app_settings.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_attachment.dart';
import '../../domain/entities/inline_attachment.dart';
import '../../domain/entities/meeting_invite.dart';
import '../../domain/usecases/delete_email.dart';
import '../../domain/usecases/download_attachment.dart';
import '../../domain/usecases/respond_to_meeting_invite.dart';
import '../../domain/usecases/send_email.dart';
import '../../infrastructure/accounts/account.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../injection_container.dart';
import '../blocs/calendar/calendar_bloc.dart';
import '../blocs/calendar/calendar_event.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_detail/email_detail_state.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/folder_list/folder_list_bloc.dart';
import '../blocs/folder_list/folder_list_event.dart';
import '../blocs/home/home_cubit.dart';
import 'email_date_formatter.dart';

class ReadingPane extends StatelessWidget {
  const ReadingPane({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfaceReading,
      child: BlocBuilder<EmailDetailBloc, EmailDetailState>(
        builder: (context, state) {
          return switch (state) {
            EmailDetailInitial() => const _EmptyState(),
            EmailDetailLoading() => Center(
                child: CircularProgressIndicator(
                    color: AppColors.accent, strokeWidth: 2),
              ),
            EmailDetailLoaded(:final email, :final senderAnomalyScore) =>
              _EmailView(email: email, senderAnomalyScore: senderAnomalyScore),
            EmailDetailError(:final message) => _ErrorState(message: message),
          };
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mark_email_read_outlined,
              size: 48, color: c.stateIcon),
          const SizedBox(height: 16),
          Text(
            'Select an email to read',
            style: TextStyle(color: c.stateText, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: c.textMuted, size: 36),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmailView extends StatelessWidget {
  const _EmailView({required this.email, this.senderAnomalyScore});
  final Email email;
  final double? senderAnomalyScore;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final calendarAvailable =
        sl<AccountManager>().calendarDatasource != null;
    final showInviteBanner =
        email.meetingInvite != null && calendarAvailable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReadingPaneToolbar(email: email),
        Divider(height: 1, color: c.border),
        _EmailHeader(email: email, senderAnomalyScore: senderAnomalyScore),
        Divider(height: 1, color: c.border),
        if (showInviteBanner) ...[
          _MeetingInviteBanner(email: email),
          Divider(height: 1, color: c.border),
        ],
        Expanded(
          child: _EmailBody(email: email),
        ),
      ],
    );
  }
}

class _ReadingPaneToolbar extends StatelessWidget {
  const _ReadingPaneToolbar({required this.email});
  final Email email;

  Future<void> _openComposeWindow(ComposeMode mode) async {
    await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({
          'mode': mode.name,
          'originalEmail': {
            'id': email.id,
            'subject': email.subject,
            'from': {'address': email.from.address, 'name': email.from.name},
            'toRecipients': email.toRecipients
                .map((r) => {'address': r.address, 'name': r.name})
                .toList(),
            'ccRecipients': email.ccRecipients
                .map((r) => {'address': r.address, 'name': r.name})
                .toList(),
          },
        }),
      ),
    );
  }

  Future<void> _confirmAndDelete(BuildContext context) async {
    final settings = sl<AppSettings>();
    final confirm = await settings.loadConfirmDeleteEmail();
    if (!context.mounted) return;

    if (confirm) {
      final account = sl<AccountManager>().activeAccount;
      final targetFolder =
          account is ImapAccount ? 'Trash' : 'Deleted Items';

      bool dontAskAgain = false;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Delete email', style: TextStyle(fontSize: 15)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Move this email to $targetFolder?',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: Checkbox(
                        value: dontAskAgain,
                        onChanged: (val) => setDialogState(
                          () => dontAskAgain = val ?? false,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      "Don't ask again",
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Delete',
                    style: TextStyle(color: Colors.redAccent)),
              ),
            ],
          ),
        ),
      );

      if (dontAskAgain) {
        await settings.saveConfirmDeleteEmail(false);
      }

      if (confirmed != true || !context.mounted) return;
    }

    if (!context.mounted) return;

    final result =
        await sl<DeleteEmail>()(DeleteEmailParams(id: email.id));

    if (!context.mounted) return;

    result.fold(
      (f) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(f.message)),
      ),
      (_) {
        context.read<EmailDetailBloc>().add(const EmailDetailCleared());
        context.read<HomeCubit>().clearEmail();
        context.read<EmailListBloc>().add(
              EmailListEmailDeleted(emailId: email.id),
            );
        if (!email.isRead && email.parentFolderId != null) {
          context.read<FolderListBloc>().add(
                FolderListUnreadCountChanged(
                  folderId: email.parentFolderId!,
                  unreadCountDelta: -1,
                  totalCountDelta: -1,
                ),
              );
        } else if (email.parentFolderId != null) {
          context.read<FolderListBloc>().add(
                FolderListUnreadCountChanged(
                  folderId: email.parentFolderId!,
                  unreadCountDelta: 0,
                  totalCountDelta: -1,
                ),
              );
        }
      },
    );
  }

  Future<void> _copyToClipboard(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: email.body));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Email body copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          _ToolbarButton(
            icon: Icons.reply_rounded,
            tooltip: 'Reply',
            color: c.textMuted,
            onPressed: () => _openComposeWindow(ComposeMode.reply),
          ),
          _ToolbarButton(
            icon: Icons.reply_all_rounded,
            tooltip: 'Reply All',
            color: c.textMuted,
            onPressed: () => _openComposeWindow(ComposeMode.replyAll),
          ),
          _ToolbarButton(
            icon: Icons.forward_to_inbox_rounded,
            tooltip: 'Forward',
            color: c.textMuted,
            onPressed: () => _openComposeWindow(ComposeMode.forward),
          ),
          const Spacer(),
          _ToolbarButton(
            icon: Icons.content_copy_outlined,
            tooltip: 'Debug: copy body to clipboard',
            color: c.textMuted,
            onPressed: () => _copyToClipboard(context),
          ),
          _ToolbarButton(
            icon: Icons.delete_outline_rounded,
            tooltip: 'Delete',
            color: c.textMuted,
            onPressed: () => _confirmAndDelete(context),
          ),
        ],
      ),
    );
  }
}

enum _InviteState { idle, loading, done, error }

class _MeetingInviteBanner extends StatefulWidget {
  const _MeetingInviteBanner({required this.email});
  final Email email;

  @override
  State<_MeetingInviteBanner> createState() => _MeetingInviteBannerState();
}

class _MeetingInviteBannerState extends State<_MeetingInviteBanner> {
  _InviteState _state = _InviteState.idle;
  String? _errorMessage;
  MeetingInviteResponseType? _responded;

  Future<void> _respond(MeetingInviteResponseType response) async {
    if (_state == _InviteState.loading) return;
    setState(() {
      _state = _InviteState.loading;
      _errorMessage = null;
    });

    final result = await sl<RespondToMeetingInvite>()(
      RespondToMeetingInviteParams(
        emailId: widget.email.id,
        response: response,
        icsData: widget.email.meetingInvite?.icsData,
        meetingStart: widget.email.meetingInvite?.meetingStart,
      ),
    );

    if (!mounted) return;
    result.fold(
      (failure) => setState(() {
        _state = _InviteState.error;
        _errorMessage = failure.message;
      }),
      (_) => setState(() {
        _state = _InviteState.done;
        _responded = response;
      }),
    );

    if (result.isRight() && mounted) {
      final calendarState = context.read<CalendarBloc>().state;
      context.read<CalendarBloc>().add(
            CalendarWeekLoadRequested(weekStart: calendarState.weekStart),
          );

      final email = widget.email;
      final deleteResult =
          await sl<DeleteEmail>()(DeleteEmailParams(id: email.id));
      if (!mounted) return;
      deleteResult.fold(
        (_) {},
        (_) {
          context.read<EmailDetailBloc>().add(const EmailDetailCleared());
          context.read<HomeCubit>().clearEmail();
          context
              .read<EmailListBloc>()
              .add(EmailListEmailDeleted(emailId: email.id));
          if (email.parentFolderId != null) {
            context.read<FolderListBloc>().add(
                  FolderListUnreadCountChanged(
                    folderId: email.parentFolderId!,
                    unreadCountDelta: email.isRead ? 0 : -1,
                    totalCountDelta: -1,
                  ),
                );
          }
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      color: c.surfacePanel,
      child: switch (_state) {
        _InviteState.loading => Row(
            children: [
              Icon(Icons.calendar_today_rounded, size: 14, color: c.textDimmed),
              const SizedBox(width: 8),
              Text(
                'Meeting invitation',
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppColors.accent),
              ),
            ],
          ),
        _InviteState.done => Row(
            children: [
              Icon(Icons.check_circle_outline_rounded,
                  size: 14, color: AppColors.accent),
              const SizedBox(width: 8),
              Text(
                switch (_responded!) {
                  MeetingInviteResponseType.accept => 'Accepted',
                  MeetingInviteResponseType.tentative => 'Tentatively accepted',
                  MeetingInviteResponseType.decline => 'Declined',
                },
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
            ],
          ),
        _InviteState.error => Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 14, color: Colors.redAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _errorMessage ?? 'Something went wrong',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _InviteResponseButton(
                label: 'Retry',
                icon: Icons.refresh_rounded,
                onPressed: () => setState(() => _state = _InviteState.idle),
              ),
            ],
          ),
        _InviteState.idle => Row(
            children: [
              Icon(Icons.calendar_today_rounded, size: 14, color: c.textDimmed),
              const SizedBox(width: 8),
              Text(
                'Meeting invitation',
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
              const Spacer(),
              _InviteResponseButton(
                label: 'Accept',
                icon: Icons.check_rounded,
                onPressed: () => _respond(MeetingInviteResponseType.accept),
              ),
              const SizedBox(width: 6),
              _InviteResponseButton(
                label: 'Maybe',
                icon: Icons.help_outline_rounded,
                onPressed: () => _respond(MeetingInviteResponseType.tentative),
              ),
              const SizedBox(width: 6),
              _InviteResponseButton(
                label: 'Decline',
                icon: Icons.close_rounded,
                onPressed: () => _respond(MeetingInviteResponseType.decline),
              ),
            ],
          ),
      },
    );
  }
}

class _InviteResponseButton extends StatefulWidget {
  const _InviteResponseButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_InviteResponseButton> createState() => _InviteResponseButtonState();
}

class _InviteResponseButtonState extends State<_InviteResponseButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: widget.onPressed,
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 70),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _isPressed
                ? AppColors.accent.withAlpha(70)
                : AppColors.accent.withAlpha(30),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: AppColors.accent.withAlpha(80), width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 11, color: c.textTertiary),
              const SizedBox(width: 4),
              Text(
                widget.label,
                style: TextStyle(color: c.textTertiary, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16, color: color),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: onPressed,
    );
  }
}

class _EmailHeader extends StatelessWidget {
  const _EmailHeader({required this.email, this.senderAnomalyScore});
  final Email email;
  final double? senderAnomalyScore;

  static Color? _anomalyColor(double? score) {
    if (score == null) return null;
    final t = ((score - 0.75) / 0.25).clamp(0.0, 1.0);
    return Color.lerp(Colors.pink.shade100, Colors.red.shade700, t);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            email.subject,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 16),
          _AnomalousFromRow(
            email: email,
            highlightColor: _anomalyColor(senderAnomalyScore),
          ),
          if (email.toRecipients.isNotEmpty) ...[
            const SizedBox(height: 6),
            _MetaRow(
              icon: Icons.mail_outline_rounded,
              label: 'To',
              value: email.toRecipients
                  .map((r) => r.displayName)
                  .join(', '),
            ),
          ],
          if (email.ccRecipients.isNotEmpty) ...[
            const SizedBox(height: 6),
            _MetaRow(
              icon: Icons.people_outline_rounded,
              label: 'Cc',
              value: email.ccRecipients
                  .map((r) => r.displayName)
                  .join(', '),
            ),
          ],
          const SizedBox(height: 6),
          _MetaRow(
            icon: Icons.schedule_rounded,
            label: 'Date',
            value: formatEmailDateLong(email.receivedDateTime),
          ),
          if (email.attachments.isNotEmpty) ...[
            const SizedBox(height: 10),
            _AttachmentsSection(
              emailId: email.id,
              attachments: email.attachments,
            ),
          ],
        ],
      ),
    );
  }
}

class _AnomalousFromRow extends StatelessWidget {
  const _AnomalousFromRow({required this.email, this.highlightColor});

  final Email email;
  final Color? highlightColor;

  @override
  Widget build(BuildContext context) {
    final row = _MetaRow(
      icon: Icons.person_outline_rounded,
      label: 'From',
      value: '${email.from.displayName} <${email.from.address}>',
    );

    if (highlightColor == null) return row;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: highlightColor!.withAlpha(60),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: row,
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: c.textDimmed),
        const SizedBox(width: 6),
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: TextStyle(
              color: c.textDimmed,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: c.textTertiary,
              fontSize: 12,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _AttachmentsSection extends StatelessWidget {
  const _AttachmentsSection({
    required this.emailId,
    required this.attachments,
  });
  final String emailId;
  final List<EmailAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.attach_file_rounded, size: 14, color: c.textDimmed),
        const SizedBox(width: 6),
        SizedBox(
          width: 44,
          child: Text(
            'Files',
            style: TextStyle(
              color: c.textDimmed,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: attachments
                    .map((a) =>
                        _AttachmentChip(emailId: emailId, attachment: a))
                    .toList(),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: _SaveAllButton(
                  emailId: emailId,
                  attachments: attachments,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SaveAllButton extends StatefulWidget {
  const _SaveAllButton({required this.emailId, required this.attachments});
  final String emailId;
  final List<EmailAttachment> attachments;

  @override
  State<_SaveAllButton> createState() => _SaveAllButtonState();
}

class _SaveAllButtonState extends State<_SaveAllButton> {
  bool _isLoading = false;
  bool _isPressed = false;
  int _completed = 0;
  int _total = 0;

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _saveAll() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _completed = 0;
      _total = widget.attachments.length;
    });
    try {
      if (_isMobile) {
        await _saveAllMobile();
      } else {
        await _saveAllDesktop();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _completed = 0;
          _total = 0;
        });
      }
    }
  }

  Future<void> _saveAllDesktop() async {
    final directory = await getDirectoryPath();
    if (directory == null || !mounted) return;

    final errors = <String>[];
    for (final attachment in widget.attachments) {
      final result = await sl<DownloadAttachment>()(DownloadAttachmentParams(
        messageId: widget.emailId,
        attachmentId: attachment.id,
      ));
      if (!mounted) return;
      await result.fold(
        (f) async => errors.add('${attachment.name}: ${f.message}'),
        (bytes) async {
          try {
            await File('$directory/${attachment.name}').writeAsBytes(bytes);
          } catch (e) {
            errors.add('${attachment.name}: $e');
          }
        },
      );
      if (mounted) setState(() => _completed++);
    }

    if (!mounted) return;
    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save:\n${errors.join('\n')}')),
      );
    }
  }

  Future<void> _saveAllMobile() async {
    final dir = await getTemporaryDirectory();

    final errors = <String>[];
    final xFiles = <XFile>[];
    for (final attachment in widget.attachments) {
      final result = await sl<DownloadAttachment>()(DownloadAttachmentParams(
        messageId: widget.emailId,
        attachmentId: attachment.id,
      ));
      if (!mounted) return;
      await result.fold(
        (f) async => errors.add(attachment.name),
        (bytes) async {
          final path = '${dir.path}/${attachment.name}';
          await File(path).writeAsBytes(bytes);
          xFiles.add(XFile(path, mimeType: attachment.contentType));
        },
      );
      if (mounted) setState(() => _completed++);
    }

    if (!mounted) return;
    if (xFiles.isNotEmpty) {
      await SharePlus.instance.share(ShareParams(files: xFiles));
    }
    if (!mounted) return;
    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to download: ${errors.join(', ')}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isMultipleFiles = _total > 1;
    final progress = _total > 0 ? _completed / _total : 0.0;

    final BoxDecoration decoration;
    if (_isLoading && isMultipleFiles) {
      decoration = BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.accent.withAlpha(90),
            AppColors.accent.withAlpha(90),
            c.badgeBg,
            c.badgeBg,
          ],
          stops: [0.0, progress, progress, 1.0],
        ),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppColors.accent.withAlpha(80), width: 0.5),
      );
    } else {
      decoration = BoxDecoration(
        color: _isPressed ? AppColors.accent.withAlpha(70) : c.badgeBg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppColors.accent.withAlpha(80), width: 0.5),
      );
    }

    return GestureDetector(
      onTap: _saveAll,
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 70),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: decoration,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isLoading)
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppColors.accent,
                  ),
                )
              else
                Icon(Icons.save_alt_rounded, size: 11, color: c.textTertiary),
              const SizedBox(width: 4),
              Text(
                'Save all',
                style: TextStyle(color: c.textTertiary, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachmentChip extends StatefulWidget {
  const _AttachmentChip({required this.emailId, required this.attachment});
  final String emailId;
  final EmailAttachment attachment;

  @override
  State<_AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends State<_AttachmentChip> {
  bool _isLoading = false;

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static IconData _iconFor(String contentType, String name) {
    final ct = contentType.toLowerCase();
    final ext =
        name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (ct.startsWith('image/')) { return Icons.image_rounded; }
    if (ct.contains('pdf') || ext == 'pdf') { return Icons.picture_as_pdf_rounded; }
    if (ct.contains('word') || ext == 'doc' || ext == 'docx') { return Icons.description_rounded; }
    if (ct.contains('excel') || ct.contains('spreadsheet') ||
        ext == 'xls' || ext == 'xlsx' || ext == 'csv') { return Icons.table_chart_rounded; }
    if (ct.contains('powerpoint') || ct.contains('presentation') ||
        ext == 'ppt' || ext == 'pptx') { return Icons.slideshow_rounded; }
    if (ct.contains('zip') || ct.contains('archive') ||
        ext == 'zip' || ext == 'rar' || ext == '7z') { return Icons.folder_zip_rounded; }
    if (ct.startsWith('audio/')) { return Icons.audio_file_rounded; }
    if (ct.startsWith('video/')) { return Icons.video_file_rounded; }
    return Icons.attach_file_rounded;
  }

  Future<void> _withBytes(Future<void> Function(List<int> bytes) action) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      final result = await sl<DownloadAttachment>()(DownloadAttachmentParams(
        messageId: widget.emailId,
        attachmentId: widget.attachment.id,
      ));
      if (!mounted) return;
      await result.fold(
        (failure) async {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not download: ${failure.message}')),
          );
        },
        action,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _open() => _withBytes((bytes) async {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/${widget.attachment.name}');
        await file.writeAsBytes(bytes);
        await OpenFile.open(file.path);
      });

  Future<void> _saveAs() => _withBytes((bytes) async {
        if (_isMobile) {
          // Mobile: share sheet lets the user pick Files / Downloads
          final dir = await getTemporaryDirectory();
          final tmp = File('${dir.path}/${widget.attachment.name}');
          await tmp.writeAsBytes(bytes);
          await SharePlus.instance.share(ShareParams(
            files: [XFile(tmp.path, mimeType: widget.attachment.contentType)],
          ));
        } else {
          // Desktop: native save-as dialog
          final location = await getSaveLocation(
            suggestedName: widget.attachment.name,
          );
          if (location != null) {
            await File(location.path).writeAsBytes(bytes);
          }
        }
      });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: _isMobile ? _open : null,
      onDoubleTap: _isMobile ? null : _open,
      onLongPress: _isMobile ? _saveAs : null,
      onSecondaryTap: _isMobile ? null : _saveAs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: c.badgeBg,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.accent,
                ),
              )
            else
              Icon(
                _iconFor(widget.attachment.contentType, widget.attachment.name),
                size: 12,
                color: c.textMuted,
              ),
            const SizedBox(width: 4),
            Text(
              widget.attachment.name,
              style: TextStyle(color: c.textTertiary, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmailBody extends StatelessWidget {
  const _EmailBody({required this.email});
  final Email email;

  static String _senderDomain(String address) {
    final at = address.lastIndexOf('@');
    if (at == -1 || at == address.length - 1) return address.toLowerCase();
    return address.substring(at + 1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    if (email.bodyType == EmailBodyType.html) {
      return _HtmlBodyWebView(
        html: email.body,
        inlineAttachments: email.inlineAttachments,
        senderDomain: _senderDomain(email.from.address),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
      child: SelectableText(
        email.body,
        style: TextStyle(
          color: c.textBody,
          fontSize: 14,
          height: 1.6,
        ),
      ),
    );
  }
}

class _HtmlBodyWebView extends StatefulWidget {
  const _HtmlBodyWebView({
    required this.html,
    required this.inlineAttachments,
    required this.senderDomain,
  });
  final String html;
  final List<InlineAttachment> inlineAttachments;
  final String senderDomain;

  @override
  State<_HtmlBodyWebView> createState() => _HtmlBodyWebViewState();
}

class _HtmlBodyWebViewState extends State<_HtmlBodyWebView> {
  // webview_flutter controller — used on macOS / Android / iOS.
  WebViewController? _flutterController;

  // webview_windows controller — used on Windows.
  wvw.WebviewController? _windowsController;
  StreamSubscription<dynamic>? _webMessageSub;
  bool _windowsReady = false;

  bool _allowExternalImages = false;
  bool _hasBlockedImages = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      _initWindows();
    } else if (Platform.isLinux) {
      _hasBlockedImages = _hasExternalImages(widget.html);
    } else {
      _initFlutter();
    }
    _loadAlwaysAllowSetting();
  }

  // ── webview_flutter (macOS / Android / iOS) ───────────────────────────────

  void _initFlutter() {
    final (html, blocked) = _buildHtml(allowExternal: false);
    _hasBlockedImages = blocked;
    _flutterController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          final scheme = uri?.scheme ?? '';
          if (scheme == 'http' || scheme == 'https' || scheme == 'mailto') {
            launchUrl(uri!, mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadHtmlString(html);
  }

  // ── webview_windows ───────────────────────────────────────────────────────

  Future<void> _initWindows() async {
    final controller = wvw.WebviewController();
    _windowsController = controller;
    try {
      await controller.initialize();
    } catch (e) {
      debugPrint('[NightMail] WebView2 init failed: $e');
      return;
    }

    // Intercept link clicks: inject a capture-phase listener that posts the
    // href via the WebView2 host-object channel and cancels the navigation.
    await controller.addScriptToExecuteOnDocumentCreated('''
      document.addEventListener('click', function(e) {
        var a = e.target.closest('a[href]');
        if (a) {
          var scheme = a.href.split(':')[0].toLowerCase();
          if (scheme === 'http' || scheme === 'https' || scheme === 'mailto') {
            e.preventDefault();
            e.stopImmediatePropagation();
            window.chrome.webview.postMessage(a.href);
          }
        }
      }, true);
    ''');

    _webMessageSub = controller.webMessage.listen((msg) {
      final url = msg?.toString() ?? '';
      final uri = Uri.tryParse(url);
      if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
    });

    // Also catch any direct navigation that slips through (e.g. form submit).
    controller.url.listen((url) {
      final uri = Uri.tryParse(url);
      final scheme = uri?.scheme ?? '';
      if (scheme == 'http' || scheme == 'https') {
        launchUrl(uri!, mode: LaunchMode.externalApplication);
        // Reload the last-known content to stay on the email.
        final (html, _) = _buildHtml(allowExternal: _allowExternalImages);
        controller.loadStringContent(html);
      }
    });

    final (html, blocked) = _buildHtml(allowExternal: false);
    _hasBlockedImages = blocked;
    await controller.loadStringContent(html);

    if (mounted) setState(() => _windowsReady = true);
  }

  // ── shared helpers ────────────────────────────────────────────────────────

  bool _hasExternalImages(String html) =>
      RegExp(r'''src=(["'])https?://''', caseSensitive: false).hasMatch(html);

  Future<void> _loadAlwaysAllowSetting() async {
    final domains = await sl<AppSettings>().loadExternalImageDomains();
    if (!mounted || !domains.contains(widget.senderDomain)) return;
    _reloadWith(allowExternal: true);
  }

  @override
  void didUpdateWidget(_HtmlBodyWebView old) {
    super.didUpdateWidget(old);
    final emailChanged = old.html != widget.html ||
        old.inlineAttachments != widget.inlineAttachments;
    final senderChanged = old.senderDomain != widget.senderDomain;
    if (emailChanged || senderChanged) {
      if (Platform.isLinux) {
        setState(() {
          _allowExternalImages = false;
          _hasBlockedImages = _hasExternalImages(widget.html);
        });
        _loadAlwaysAllowSetting();
      } else {
        _reloadWith(allowExternal: false);
        _loadAlwaysAllowSetting();
      }
    }
  }

  @override
  void dispose() {
    _webMessageSub?.cancel();
    _windowsController?.dispose();
    super.dispose();
  }

  void _reloadWith({required bool allowExternal}) {
    final (html, blocked) = _buildHtml(allowExternal: allowExternal);
    setState(() {
      _allowExternalImages = allowExternal;
      _hasBlockedImages = blocked;
    });
    if (Platform.isWindows) {
      if (_windowsReady) _windowsController?.loadStringContent(html);
    } else if (Platform.isLinux) {
      // Linux uses flutter_widget_from_html — setState above is sufficient.
    } else {
      _flutterController?.loadHtmlString(html);
    }
  }

  void _downloadOnce() => _reloadWith(allowExternal: true);

  Future<void> _alwaysDownload() async {
    await sl<AppSettings>().saveExternalImageDomain(widget.senderDomain);
    if (mounted) _reloadWith(allowExternal: true);
  }

  (String, bool) _buildHtml({required bool allowExternal}) {
    // Replace cid: references with data: URLs so inline images render.
    var resolved = widget.html;
    for (final attachment in widget.inlineAttachments) {
      final cid = attachment.contentId;
      // Strip angle brackets if present (RFC 2392 uses bare CID, MIME uses <CID>).
      final bare = cid.startsWith('<') && cid.endsWith('>')
          ? cid.substring(1, cid.length - 1)
          : cid;
      final dataUrl =
          'data:${attachment.contentType};base64,${base64Encode(attachment.contentBytes)}';
      resolved = resolved.replaceAll('cid:$bare', dataUrl);
    }

    bool hasBlockedImages = false;
    if (!allowExternal) {
      // Replace external src attributes in <img> tags with data-blocked-src so
      // images don't load. The CSS rule below hides them entirely.
      resolved = resolved.replaceAllMapped(
        RegExp(r'<img\b([^>]*)>', caseSensitive: false),
        (imgMatch) {
          final attrs = imgMatch.group(1)!;
          final newAttrs = attrs.replaceFirstMapped(
            RegExp(r'''src=(["'])(https?://[^"']+)\1''', caseSensitive: false),
            (sm) {
              hasBlockedImages = true;
              return 'data-blocked-src=${sm.group(1)}${sm.group(2)}${sm.group(1)}';
            },
          );
          return '<img$newAttrs>';
        },
      );
    }

    // Inject viewport + minimal responsive overrides before </head>.
    const injected = '''
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0">
<style>
* { box-sizing: border-box !important; }
body { margin: 0; padding: 20px 28px 40px; }
img { max-width: 100% !important; height: auto !important; }
img[data-blocked-src] { display: none !important; }
</style>
''';
    final headEnd = resolved.indexOf('</head>');
    if (headEnd != -1) {
      resolved = resolved.substring(0, headEnd) +
          injected +
          resolved.substring(headEnd);
    } else {
      resolved = '<html><head>$injected</head><body>$resolved</body></html>';
    }

    return (resolved, hasBlockedImages);
  }

  @override
  Widget build(BuildContext context) {
    final Widget webviewWidget;
    if (Platform.isWindows) {
      final ctrl = _windowsController;
      webviewWidget = _windowsReady && ctrl != null
          ? wvw.Webview(ctrl)
          : const SizedBox.shrink();
    } else if (Platform.isLinux) {
      final c = context.colors;
      final (html, _) = _buildHtml(allowExternal: _allowExternalImages);
      webviewWidget = SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
        child: HtmlWidget(
          html,
          textStyle:
              TextStyle(color: c.textBody, fontSize: 14, height: 1.6),
          onTapUrl: (url) async {
            final uri = Uri.tryParse(url);
            if (uri != null) {
              final s = uri.scheme;
              if (s == 'http' || s == 'https' || s == 'mailto') {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            }
            return true;
          },
        ),
      );
    } else {
      final ctrl = _flutterController;
      webviewWidget = ctrl != null
          ? WebViewWidget(controller: ctrl)
          : const SizedBox.shrink();
    }

    return Column(
      children: [
        Expanded(child: webviewWidget),
        if (_hasBlockedImages && !_allowExternalImages)
          _ImageBlockedBar(
            onDownloadOnce: _downloadOnce,
            onAlwaysDownload: _alwaysDownload,
          ),
      ],
    );
  }
}

class _ImageBlockedBar extends StatelessWidget {
  const _ImageBlockedBar({
    required this.onDownloadOnce,
    required this.onAlwaysDownload,
  });

  final VoidCallback onDownloadOnce;
  final VoidCallback onAlwaysDownload;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 29,
      decoration: BoxDecoration(
        color: c.surfacePanel,
        border: Border(top: BorderSide(color: c.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(Icons.hide_image_outlined, size: 13, color: c.textMuted),
          const SizedBox(width: 6),
          Text(
            'External images blocked',
            style: TextStyle(color: c.textMuted, fontSize: 11),
          ),
          const Spacer(),
          _StatusBarButton(
            label: 'Download once',
            onPressed: onDownloadOnce,
          ),
          const SizedBox(width: 4),
          _StatusBarButton(
            label: 'Always download',
            onPressed: onAlwaysDownload,
          ),
        ],
      ),
    );
  }
}

class _StatusBarButton extends StatefulWidget {
  const _StatusBarButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  State<_StatusBarButton> createState() => _StatusBarButtonState();
}

class _StatusBarButtonState extends State<_StatusBarButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: widget.onPressed,
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 70),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _isPressed
                ? AppColors.accent.withAlpha(70)
                : AppColors.accent.withAlpha(30),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: AppColors.accent.withAlpha(80), width: 0.5),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: c.textTertiary,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}
