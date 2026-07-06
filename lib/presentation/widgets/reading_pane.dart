import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:html_view/html_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_selector/file_selector.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'html_body_view.dart';
import 'contact_hover_card.dart';

import '../../core/settings/app_settings.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_address.dart';
import '../../domain/entities/email_attachment.dart';
import '../../domain/entities/inline_attachment.dart';
import '../../domain/entities/meeting_invite.dart';
import '../../domain/usecases/check_sender_anomaly.dart';
import '../../domain/usecases/delete_email.dart';
import '../../domain/usecases/download_attachment.dart';
import '../../domain/usecases/cancel_meeting_from_email.dart';
import '../../domain/usecases/remove_cancelled_meeting.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/usecases/get_calendar_events.dart';
import '../../domain/usecases/propose_new_time_from_email.dart';
import '../../domain/usecases/respond_to_meeting_invite.dart';
import '../../domain/usecases/send_email.dart';
import 'package:intl/intl.dart';
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
import '../pages/compose_window.dart';
import 'email_date_formatter.dart';

class ReadingPane extends StatelessWidget {
  const ReadingPane({super.key, this.onBack});

  final VoidCallback? onBack;

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
            EmailDetailLoaded(:final email, :final senderAnomaly) =>
              _EmailView(key: ValueKey(email.id), email: email, senderAnomaly: senderAnomaly, onBack: onBack),
            EmailDetailError(:final message) => _ErrorState(message: message, onBack: onBack),
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
  const _ErrorState({required this.message, this.onBack});
  final String message;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onBack != null)
          IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded, size: 16, color: c.textMuted),
            tooltip: 'Back',
            onPressed: onBack,
          ),
        Expanded(
          child: Center(
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
          ),
        ),
      ],
    );
  }
}

class _EmailView extends StatefulWidget {
  const _EmailView({super.key, required this.email, this.senderAnomaly, this.onBack});
  final Email email;
  final SenderAnomalyResult? senderAnomaly;
  final VoidCallback? onBack;

  @override
  State<_EmailView> createState() => _EmailViewState();
}

class _EmailViewState extends State<_EmailView> {
  String? _pdfPreviewPath;
  String? _pdfPreviewName;
  String? _pdfPreviewAttachmentId;

  void _showPdfPreview(String path, String name, String attachmentId) {
    setState(() {
      _pdfPreviewPath = path;
      _pdfPreviewName = name;
      _pdfPreviewAttachmentId = attachmentId;
    });
  }

  void _closePdfPreview() {
    setState(() {
      _pdfPreviewPath = null;
      _pdfPreviewName = null;
      _pdfPreviewAttachmentId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final calendarAvailable =
        sl<AccountManager>().calendarDatasource != null;
    final meetingType = widget.email.meetingInvite?.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReadingPaneToolbar(email: widget.email, onBack: widget.onBack),
        Divider(height: 1, color: c.border),
        _EmailHeader(
          email: widget.email,
          senderAnomaly: widget.senderAnomaly,
          onPdfPreview: _showPdfPreview,
          activePdfAttachmentId: _pdfPreviewAttachmentId,
        ),
        Divider(height: 1, color: c.border),
        if (calendarAvailable && meetingType == MeetingEmailType.invitation) ...[
          _MeetingInviteBanner(email: widget.email),
          Divider(height: 1, color: c.border),
        ],
        if (calendarAvailable && meetingType == MeetingEmailType.cancellation) ...[
          _MeetingCancellationBanner(email: widget.email),
          Divider(height: 1, color: c.border),
        ],
        if (calendarAvailable && meetingType == MeetingEmailType.declineNotification) ...[
          _MeetingDeclineNotificationBanner(email: widget.email),
          Divider(height: 1, color: c.border),
        ],
        Expanded(
          child: _pdfPreviewPath != null
              ? _PdfPreview(
                  key: ValueKey(_pdfPreviewPath),
                  filePath: _pdfPreviewPath!,
                  fileName: _pdfPreviewName!,
                  onClose: _closePdfPreview,
                )
              : _EmailBody(email: widget.email),
        ),
      ],
    );
  }
}

class _ReadingPaneToolbar extends StatelessWidget {
  const _ReadingPaneToolbar({required this.email, this.onBack});
  final Email email;
  final VoidCallback? onBack;

  Future<void> _openComposeWindow(BuildContext context, ComposeMode mode) async {
    await ComposeWindowApp.open(context, mode: mode, originalEmail: email, onSent: onBack);
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          if (onBack != null) ...[
            _ToolbarButton(
              icon: Icons.arrow_back_ios_new_rounded,
              tooltip: 'Back',
              color: context.colors.textMuted,
              onPressed: onBack!,
            ),
            const SizedBox(width: 4),
          ],
          _ToolbarButton(
            icon: Icons.reply_rounded,
            tooltip: 'Reply',
            color: c.textMuted,
            onPressed: () => _openComposeWindow(context, ComposeMode.reply),
          ),
          _ToolbarButton(
            icon: Icons.reply_all_rounded,
            tooltip: 'Reply All',
            color: c.textMuted,
            onPressed: () => _openComposeWindow(context, ComposeMode.replyAll),
          ),
          _ToolbarButton(
            icon: Icons.forward_to_inbox_rounded,
            tooltip: 'Forward',
            color: c.textMuted,
            onPressed: () => _openComposeWindow(context, ComposeMode.forward),
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
            iconSize: 20,
            onPressed: () => _confirmAndDelete(context),
          ),
        ],
      ),
    );
  }
}

enum _InviteState { idle, loading, done, error, proposing }

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
  bool _proposedNewTime = false;
  List<CalendarEvent> _conflicts = [];
  bool _addNote = false;
  final TextEditingController _noteController = TextEditingController();
  DateTime? _proposedStart;
  DateTime? _proposedEnd;

  @override
  void initState() {
    super.initState();
    _checkConflicts();
    final invite = widget.email.meetingInvite;
    _proposedStart = invite?.meetingStart;
    _proposedEnd = invite?.meetingEnd ??
        invite?.meetingStart?.add(const Duration(hours: 1));
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _checkConflicts() async {
    final invite = widget.email.meetingInvite;
    final start = invite?.meetingStart;
    final end = invite?.meetingEnd ?? start?.add(const Duration(hours: 1));
    if (start == null) return;

    final result = await sl<GetCalendarEvents>()(GetCalendarEventsParams(
      startDateTime: start.subtract(const Duration(minutes: 1)),
      endDateTime: end!,
    ));
    if (!mounted) return;
    result.fold((_) {}, (events) {
      final conflicts = events.where((e) {
        if (e.status == CalendarEventStatus.free) return false;
        // Skip the calendar entry auto-created for this invite itself (same start+end).
        if (e.start.toUtc().isAtSameMomentAs(start.toUtc()) &&
            e.end.toUtc().isAtSameMomentAs(end.toUtc())) return false;
        return e.start.isBefore(end) && e.end.isAfter(start);
      }).toList();
      if (conflicts.isNotEmpty) setState(() => _conflicts = conflicts);
    });
  }

  String _formatMeetingTime(MeetingInvite invite) {
    final start = invite.meetingStart;
    final end = invite.meetingEnd;
    if (start == null) return '';
    final local = start.toLocal();
    if (invite.isAllDay) {
      return DateFormat('EEE d MMM yyyy').format(local);
    }
    final datePart = DateFormat('EEE d MMM yyyy').format(local);
    final startTime = DateFormat('h:mm a').format(local);
    if (end != null) {
      final endTime = DateFormat('h:mm a').format(end.toLocal());
      return '$datePart  $startTime – $endTime';
    }
    return '$datePart  $startTime';
  }

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
        message: _addNote ? _noteController.text.trim() : null,
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

  Future<void> _sendProposal() async {
    final start = _proposedStart;
    final end = _proposedEnd;
    if (start == null || end == null) return;
    if (_state == _InviteState.loading) return;
    setState(() {
      _state = _InviteState.loading;
      _errorMessage = null;
    });

    final result = await sl<ProposeNewTimeFromEmail>()(
      ProposeNewTimeFromEmailParams(
        emailId: widget.email.id,
        newStart: start,
        newEnd: end,
        icsData: widget.email.meetingInvite?.icsData,
        meetingStart: widget.email.meetingInvite?.meetingStart,
        message: _addNote ? _noteController.text.trim() : null,
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
        _proposedNewTime = true;
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

  Future<void> _pickDateTime({
    required bool isStart,
  }) async {
    final current = isStart ? _proposedStart : _proposedEnd;
    final base = current ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base.toLocal(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base.toLocal()),
    );
    if (time == null || !mounted) return;
    final combined = DateTime(
      date.year, date.month, date.day, time.hour, time.minute,
    ).toUtc();
    setState(() {
      if (isStart) {
        _proposedStart = combined;
        // Keep end after start; nudge it if needed.
        final end = _proposedEnd;
        if (end != null && !end.isAfter(combined)) {
          _proposedEnd = combined.add(const Duration(hours: 1));
        }
      } else {
        _proposedEnd = combined;
      }
    });
  }

  Widget _buildIdleState(AppColors c) {
    final invite = widget.email.meetingInvite;
    final timeStr = invite != null ? _formatMeetingTime(invite) : '';
    final location = invite?.location;
    final hasDetails = timeStr.isNotEmpty || location != null;

    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
        const SizedBox(width: 6),
        _InviteResponseButton(
          label: 'Propose New Time',
          icon: Icons.schedule_rounded,
          onPressed: () => setState(() => _state = _InviteState.proposing),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.calendar_today_rounded,
                  size: 14, color: c.textDimmed),
            ),
            const SizedBox(width: 8),
            if (hasDetails)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (timeStr.isNotEmpty)
                      Text(timeStr,
                          style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500)),
                    if (location != null) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(Icons.place_outlined,
                              size: 12, color: c.textDimmed),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(location,
                                style: TextStyle(
                                    color: c.textTertiary, fontSize: 11),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              )
            else ...[
              Text('Meeting invitation',
                  style: TextStyle(color: c.textTertiary, fontSize: 12)),
              const Spacer(),
            ],
            const SizedBox(width: 12),
            buttons,
          ],
        ),
        if (_conflicts.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 12, color: Colors.orange.shade700),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Conflicts with: ${_conflicts.map((e) => e.subject).join(', ')}',
                  style:
                      TextStyle(color: Colors.orange.shade700, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
        _buildNoteRow(c),
      ],
    );
  }

  Widget _buildProposingState(AppColors c) {
    String fmt(DateTime? dt) {
      if (dt == null) return '—';
      return _formatMeetingTime(MeetingInvite(
        meetingStart: dt,
        meetingEnd: dt.add(const Duration(seconds: 1)),
        isAllDay: false,
      )).split('  ').last;
    }

    String fmtDate(DateTime? dt) {
      if (dt == null) return '—';
      return DateFormat('EEE d MMM yyyy').format(dt.toLocal());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.schedule_rounded, size: 14, color: c.textDimmed),
            const SizedBox(width: 8),
            Text('Propose new time',
                style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 36,
              child: Text('From',
                  style: TextStyle(color: c.textTertiary, fontSize: 11)),
            ),
            _DateTimeChip(
              label: fmtDate(_proposedStart),
              onTap: () => _pickDateTime(isStart: true),
              c: c,
            ),
            const SizedBox(width: 6),
            _DateTimeChip(
              label: fmt(_proposedStart),
              onTap: () => _pickDateTime(isStart: true),
              c: c,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(
              width: 36,
              child: Text('To',
                  style: TextStyle(color: c.textTertiary, fontSize: 11)),
            ),
            _DateTimeChip(
              label: fmtDate(_proposedEnd),
              onTap: () => _pickDateTime(isStart: false),
              c: c,
            ),
            const SizedBox(width: 6),
            _DateTimeChip(
              label: fmt(_proposedEnd),
              onTap: () => _pickDateTime(isStart: false),
              c: c,
            ),
            const Spacer(),
            _InviteResponseButton(
              label: 'Send',
              icon: Icons.send_rounded,
              onPressed: _sendProposal,
            ),
            const SizedBox(width: 6),
            _InviteResponseButton(
              label: 'Cancel',
              icon: Icons.close_rounded,
              onPressed: () => setState(() => _state = _InviteState.idle),
            ),
          ],
        ),
        _buildNoteRow(c),
      ],
    );
  }

  Widget _buildNoteRow(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: Checkbox(
                value: _addNote,
                onChanged: (v) => setState(() => _addNote = v ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 6),
            Text('Add note',
                style: TextStyle(color: c.textTertiary, fontSize: 11)),
          ],
        ),
        if (_addNote) ...[
          const SizedBox(height: 4),
          TextField(
            controller: _noteController,
            style: TextStyle(color: c.textPrimary, fontSize: 12),
            maxLines: 3,
            minLines: 1,
            decoration: InputDecoration(
              hintText: 'Note to organiser…',
              hintStyle: TextStyle(color: c.textDimmed, fontSize: 12),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide(color: c.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide:
                    const BorderSide(color: AppColors.accent, width: 1.5),
              ),
            ),
          ),
        ],
      ],
    );
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
                _proposedNewTime
                    ? 'Proposal sent'
                    : switch (_responded!) {
                        MeetingInviteResponseType.accept => 'Accepted',
                        MeetingInviteResponseType.tentative =>
                          'Tentatively accepted',
                        MeetingInviteResponseType.decline => 'Declined',
                      },
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
            ],
          ),
        _InviteState.error => Row(
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 14, color: Colors.redAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _errorMessage ?? 'Something went wrong',
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 12),
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
        _InviteState.idle => _buildIdleState(c),
        _InviteState.proposing => _buildProposingState(c),
      },
    );
  }
}

class _DateTimeChip extends StatelessWidget {
  const _DateTimeChip({
    required this.label,
    required this.onTap,
    required this.c,
  });

  final String label;
  final VoidCallback onTap;
  final AppColors c;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: TextStyle(color: c.textPrimary, fontSize: 11)),
      ),
    );
  }
}

class _MeetingCancellationBanner extends StatefulWidget {
  const _MeetingCancellationBanner({required this.email});
  final Email email;

  @override
  State<_MeetingCancellationBanner> createState() =>
      _MeetingCancellationBannerState();
}

class _MeetingCancellationBannerState
    extends State<_MeetingCancellationBanner> {
  _InviteState _state = _InviteState.idle;
  String? _errorMessage;

  Future<void> _remove() async {
    if (_state == _InviteState.loading) return;
    setState(() {
      _state = _InviteState.loading;
      _errorMessage = null;
    });

    final result = await sl<RemoveCancelledMeeting>()(
      RemoveCancelledMeetingParams(
        emailId: widget.email.id,
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
      (_) => setState(() => _state = _InviteState.done),
    );

    if (result.isRight() && mounted) {
      context.read<CalendarBloc>().add(
            CalendarWeekLoadRequested(
                weekStart: context.read<CalendarBloc>().state.weekStart),
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
              Icon(Icons.event_busy_rounded, size: 14, color: c.textDimmed),
              const SizedBox(width: 8),
              Text(
                'Meeting cancelled',
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
                'Removed from calendar',
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
        _InviteState.idle || _InviteState.proposing => Row(
            children: [
              Icon(Icons.event_busy_rounded, size: 14, color: c.textDimmed),
              const SizedBox(width: 8),
              Text(
                'Meeting cancelled',
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
              const Spacer(),
              _InviteResponseButton(
                label: 'Remove from calendar',
                icon: Icons.delete_outline_rounded,
                onPressed: _remove,
              ),
            ],
          ),
      },
    );
  }
}

class _MeetingDeclineNotificationBanner extends StatefulWidget {
  const _MeetingDeclineNotificationBanner({required this.email});
  final Email email;

  @override
  State<_MeetingDeclineNotificationBanner> createState() =>
      _MeetingDeclineNotificationBannerState();
}

class _MeetingDeclineNotificationBannerState
    extends State<_MeetingDeclineNotificationBanner> {
  _InviteState _state = _InviteState.idle;
  String? _errorMessage;

  Future<void> _cancel() async {
    if (_state == _InviteState.loading) return;
    setState(() {
      _state = _InviteState.loading;
      _errorMessage = null;
    });

    final result = await sl<CancelMeetingFromEmail>()(
      CancelMeetingFromEmailParams(
        emailId: widget.email.id,
        meetingStart: widget.email.meetingInvite?.meetingStart,
      ),
    );

    if (!mounted) return;
    result.fold(
      (failure) => setState(() {
        _state = _InviteState.error;
        _errorMessage = failure.message;
      }),
      (_) => setState(() => _state = _InviteState.done),
    );

    if (result.isRight() && mounted) {
      context.read<CalendarBloc>().add(
            CalendarWeekLoadRequested(
                weekStart: context.read<CalendarBloc>().state.weekStart),
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
              Icon(Icons.person_remove_outlined, size: 14, color: c.textDimmed),
              const SizedBox(width: 8),
              Text(
                'Meeting declined',
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
                'Meeting cancelled',
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
            ],
          ),
        _InviteState.error => Row(
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 14, color: Colors.redAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _errorMessage ?? 'Something went wrong',
                  style:
                      const TextStyle(color: Colors.redAccent, fontSize: 12),
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
        _InviteState.idle || _InviteState.proposing => Row(
            children: [
              Icon(Icons.person_remove_outlined, size: 14, color: c.textDimmed),
              const SizedBox(width: 8),
              Text(
                'Meeting declined',
                style: TextStyle(color: c.textTertiary, fontSize: 12),
              ),
              const Spacer(),
              _InviteResponseButton(
                label: 'Cancel meeting',
                icon: Icons.cancel_outlined,
                onPressed: _cancel,
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
    this.iconSize = 18,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: iconSize, color: color),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: onPressed,
    );
  }
}

class _EmailHeader extends StatelessWidget {
  const _EmailHeader({
    required this.email,
    this.senderAnomaly,
    this.onPdfPreview,
    this.activePdfAttachmentId,
  });
  final Email email;
  final SenderAnomalyResult? senderAnomaly;
  final void Function(String path, String name, String attachmentId)? onPdfPreview;
  final String? activePdfAttachmentId;

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
            highlightColor: _anomalyColor(senderAnomaly?.score),
            anomalyMatches: senderAnomaly?.matches,
          ),
          if (email.toRecipients.isNotEmpty) ...[
            const SizedBox(height: 6),
            _RecipientRow(
              icon: Icons.mail_outline_rounded,
              label: 'To',
              recipients: email.toRecipients,
            ),
          ],
          if (email.ccRecipients.isNotEmpty) ...[
            const SizedBox(height: 6),
            _RecipientRow(
              icon: Icons.people_outline_rounded,
              label: 'Cc',
              recipients: email.ccRecipients,
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
              onPdfPreview: onPdfPreview,
              activePdfAttachmentId: activePdfAttachmentId,
            ),
          ],
        ],
      ),
    );
  }
}

class _AnomalousFromRow extends StatelessWidget {
  const _AnomalousFromRow({
    required this.email,
    this.highlightColor,
    this.anomalyMatches,
  });

  final Email email;
  final Color? highlightColor;
  final List<({String address, String name})>? anomalyMatches;

  void _showMatchesMenu(BuildContext context, Offset position) {
    final matches = anomalyMatches;
    if (matches == null || matches.isEmpty) return;
    // Capture bloc before entering the overlay subtree — context.read won't
    // work inside PopupMenuItem because it's mounted outside the BlocProvider.
    final bloc = context.read<EmailDetailBloc>();
    final rect = RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    );
    showMenu<void>(
      context: context,
      position: rect,
      items: [
        const PopupMenuItem<void>(
          enabled: false,
          height: 28,
          child: Text(
            'Previously seen addresses for this name:',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
        ...matches.map(
          (m) => PopupMenuItem<void>(
            height: 52,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(m.address,
                          style: const TextStyle(fontSize: 12)),
                      Text(m.name,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.merge_rounded, size: 16),
                  tooltip: 'Same person — don\'t warn again',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () {
                    Navigator.of(context, rootNavigator: true).pop();
                    bloc.add(EmailDetailMergeSenderRequested(
                        matchAddress: m.address));
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final row = _MetaRow(
      icon: Icons.person_outline_rounded,
      label: 'From',
      value: '${email.from.displayName} <${email.from.address}>',
    );

    void openCompose() {
      ComposeWindowApp.open(
        context,
        mode: ComposeMode.newEmail,
        draftEmail: Email(
          id: '',
          subject: '',
          from: const EmailAddress(address: '', name: null),
          toRecipients: [email.from],
          ccRecipients: const [],
          bodyPreview: '',
          body: '',
          bodyType: EmailBodyType.text,
          isRead: true,
          receivedDateTime: DateTime.now(),
          importance: EmailImportance.normal,
        ),
      );
    }

    final Widget core;
    if (highlightColor == null) {
      core = GestureDetector(onTap: openCompose, child: row);
    } else {
      final highlighted = DecoratedBox(
        decoration: BoxDecoration(
          color: highlightColor!.withAlpha(60),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: row,
        ),
      );

      if (anomalyMatches == null || anomalyMatches!.isEmpty) {
        core = GestureDetector(onTap: openCompose, child: highlighted);
      } else {
        core = GestureDetector(
          onTap: openCompose,
          onSecondaryTapUp: (d) => _showMatchesMenu(context, d.globalPosition),
          child: highlighted,
        );
      }
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: core,
    );
  }
}

class _RecipientRow extends StatelessWidget {
  const _RecipientRow({
    required this.icon,
    required this.label,
    required this.recipients,
  });

  final IconData icon;
  final String label;
  final List<EmailAddress> recipients;

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
          child: Wrap(
            children: [
              for (int i = 0; i < recipients.length; i++)
                _buildChip(context, recipients[i], isLast: i == recipients.length - 1),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChip(BuildContext context, EmailAddress r, {required bool isLast}) {
    final c = context.colors;
    final display = isLast ? r.displayName : '${r.displayName}, ';
    final text = Text(
      display,
      style: TextStyle(color: c.textTertiary, fontSize: 12),
    );

    final account = sl<AccountManager>().activeAccount;
    if (account is GmailAccount || account is MicrosoftAccount) {
      final wrapped = r.name?.isNotEmpty == true
          ? Tooltip(message: r.address, child: text)
          : text;
      return ContactHoverTarget(
        address: r.address,
        accountId: account!.id,
        child: wrapped,
      );
    }

    if (r.name?.isNotEmpty == true) {
      return Tooltip(message: r.address, child: text);
    }
    return text;
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
    this.wrap = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool wrap;

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
            overflow: wrap ? null : TextOverflow.ellipsis,
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
    this.onPdfPreview,
    this.activePdfAttachmentId,
  });
  final String emailId;
  final List<EmailAttachment> attachments;
  final void Function(String path, String name, String attachmentId)? onPdfPreview;
  final String? activePdfAttachmentId;

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
                    .map((a) => _AttachmentChip(
                          emailId: emailId,
                          attachment: a,
                          onPdfPreview: onPdfPreview,
                          isActive: a.id == activePdfAttachmentId,
                        ))
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
  const _AttachmentChip({
    required this.emailId,
    required this.attachment,
    this.onPdfPreview,
    this.isActive = false,
  });
  final String emailId;
  final EmailAttachment attachment;
  final void Function(String path, String name, String attachmentId)? onPdfPreview;
  final bool isActive;

  @override
  State<_AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends State<_AttachmentChip> {
  bool _isLoading = false;

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  bool get _isPdf {
    final ct = widget.attachment.contentType.toLowerCase();
    final ext = widget.attachment.name.contains('.')
        ? widget.attachment.name.split('.').last.toLowerCase()
        : '';
    return ct.contains('pdf') || ext == 'pdf';
  }

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

  Future<void> _previewPdf() => _withBytes((bytes) async {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/${widget.attachment.name}');
        await file.writeAsBytes(bytes);
        widget.onPdfPreview?.call(
          file.path,
          widget.attachment.name,
          widget.attachment.id,
        );
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
    final isPdf = _isPdf;
    return GestureDetector(
      onTap: _isMobile ? _open : isPdf ? _previewPdf : null,
      onDoubleTap: _isMobile ? null : _open,
      onLongPress: _isMobile ? _saveAs : null,
      onSecondaryTap: _isMobile ? null : _saveAs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: widget.isActive
              ? AppColors.accent.withValues(alpha: 0.12)
              : c.badgeBg,
          borderRadius: BorderRadius.circular(5),
          border: widget.isActive
              ? Border.all(color: AppColors.accent.withValues(alpha: 0.4), width: 1)
              : null,
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
      return HtmlBodyView(
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

class _PdfPreview extends StatefulWidget {
  const _PdfPreview({
    super.key,
    required this.filePath,
    required this.fileName,
    required this.onClose,
  });
  final String filePath;
  final String fileName;
  final VoidCallback onClose;

  @override
  State<_PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<_PdfPreview> {
  HtmlViewController? _htmlController;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _initHtmlView();
  }

  Future<void> _initHtmlView() async {
    final ctrl = HtmlViewController();
    await ctrl.initialize();
    if (_disposed) { unawaited(ctrl.dispose()); return; }
    setState(() => _htmlController = ctrl);
    unawaited(ctrl.loadUrl(Uri.file(widget.filePath).toString()));
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_htmlController?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ctrl = _htmlController;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.picture_as_pdf_rounded, size: 14, color: c.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.fileName,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: widget.onClose,
                child: Icon(Icons.close_rounded, size: 16, color: c.textMuted),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: c.border),
        Expanded(
          child: ctrl != null
              ? HtmlViewWidget(controller: ctrl)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
