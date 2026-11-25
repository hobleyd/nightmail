import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/platform/touch_metrics.dart';
import '../../core/platform/window_utils.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/chat.dart';
import '../blocs/chat/chat_unread_cubit.dart';
import '../blocs/tasks/overdue_tasks_cubit.dart';

/// The Calendar, Tasks, Chat, AI and Commitments buttons, as a row.
///
/// Drawn at the foot of the folder panel everywhere, and on a phone also at
/// the foot of the email list — which is where the app now opens, so the
/// views have to be reachable without first backing out to the folders.
/// One widget so the two feet cannot drift apart.
///
/// On desktop a double-click brings up Calendar, Tasks, Commitments or Chat in its
/// own window — the one already open if there is one, see
/// [showOrCreateSubWindow] — and leaves the pane as it was. AI has no window
/// of its own.
class ViewShortcutButtons extends StatelessWidget {
  const ViewShortcutButtons({
    super.key,
    required this.onCalendarTapped,
    required this.onTasksTapped,
    required this.onAiTapped,
    required this.onCommitmentsTapped,
    required this.onChatTapped,
  });

  final VoidCallback onCalendarTapped;
  final VoidCallback onTasksTapped;
  final VoidCallback onAiTapped;
  final VoidCallback onCommitmentsTapped;
  final VoidCallback onChatTapped;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Red dot on the Tasks icon: the active account has something already past
    // due, in any of its lists — not only the one the pane last showed.
    final overdueTasks = context.watch<OverdueTasksCubit>().state;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ViewButton(
          icon: Icon(Icons.calendar_month_outlined,
              size: touchIcon(16), color: c.textMuted),
          tooltip: 'Calendar',
          onTap: onCalendarTapped,
          windowType: 'calendar',
        ),
        _ViewButton(
          icon: _Dotted(
            dot: overdueTasks > 0,
            child: Icon(Icons.checklist_rounded,
                size: touchIcon(16), color: c.textMuted),
          ),
          tooltip:
              overdueTasks > 0 ? 'Tasks ($overdueTasks overdue)' : 'Tasks',
          onTap: onTasksTapped,
          windowType: 'tasks',
        ),
        _ChatButton(onTap: onChatTapped),
        _ViewButton(
          icon: Icon(Icons.auto_awesome_rounded,
              size: touchIcon(16), color: c.textMuted),
          tooltip: 'AI',
          onTap: onAiTapped,
        ),
        _ViewButton(
          // A screen-sized window where the pane becomes a four-column board.
          icon: Icon(Icons.handshake_outlined,
              size: touchIcon(16), color: c.textMuted),
          tooltip: 'Commitments',
          onTap: onCommitmentsTapped,
          windowType: 'commitments',
        ),
      ],
    );
  }
}

/// The Chat button. One chat system — the account's own, or Slack alone for
/// an account without one (IMAP) — and a click toggles the pane as the other
/// buttons do. With a Slack workspace beside the account's chat it is a menu
/// of the systems instead, each with its own unread dot, and picking one
/// opens the pane on it ([ChatUnreadCubit.choose]). The dot on the icon is
/// any system's unread; the double-click still opens the chat window, which
/// starts on the account's own chat.
class _ChatButton extends StatelessWidget {
  const _ChatButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<ChatUnreadCubit>().state;
    final total = state.total;
    final String tooltip;
    if (total == 0) {
      tooltip = 'Chat';
    } else if (!state.hasChoice) {
      tooltip = 'Chat ($total unread)';
    } else {
      tooltip = 'Chat — ${[
        for (final s in state.sources)
          if (state.unreadIn(s.id) > 0) '${state.unreadIn(s.id)} unread in ${s.label}',
      ].join(', ')}';
    }
    return Builder(
      builder: (buttonContext) => _ViewButton(
        // The pane chats with the selected email's people; the window is
        // every chat and channel.
        icon: _Dotted(
          dot: total > 0,
          child: Icon(Icons.forum_outlined,
              size: touchIcon(16), color: c.textMuted),
        ),
        tooltip: tooltip,
        onTap: state.hasChoice ? () => _choose(buttonContext) : onTap,
        windowType: 'chat',
      ),
    );
  }

  Future<void> _choose(BuildContext buttonContext) async {
    final cubit = buttonContext.read<ChatUnreadCubit>();
    final box = buttonContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final c = buttonContext.colors;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight =
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    final state = cubit.state;
    final picked = await showMenu<String>(
      context: buttonContext,
      color: c.surfacePanel,
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final s in state.sources)
          PopupMenuItem<String>(
            value: s.id,
            height: touchRowHeight(36),
            child: _ChatSourceRow(
              source: s,
              unread: state.unreadIn(s.id),
              chosen: s.id == state.chosen?.id,
            ),
          ),
      ],
    );
    if (picked == null) return;
    cubit.choose(picked);
    onTap();
  }
}

/// One chat system in the Chat button's menu: its name, a red dot and count
/// when it has unread chats, and a tick on the one the pane shows.
class _ChatSourceRow extends StatelessWidget {
  const _ChatSourceRow({
    required this.source,
    required this.unread,
    required this.chosen,
  });

  final ChatSource source;
  final int unread;
  final bool chosen;

  static IconData iconFor(ChatSourceKind kind) => switch (kind) {
        ChatSourceKind.teams => Icons.groups_2_outlined,
        ChatSourceKind.nightmailServer => Icons.forum_outlined,
        ChatSourceKind.googleChat => Icons.chat_bubble_outline_rounded,
        ChatSourceKind.slack => Icons.tag_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        SizedBox(
          width: 18,
          child: chosen
              ? Icon(Icons.check_rounded, size: 15, color: c.textSecondary)
              : null,
        ),
        const SizedBox(width: 4),
        Icon(iconFor(source.kind), size: 16, color: c.textMuted),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            source.label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: c.textPrimary),
          ),
        ),
        if (source.needsReconnect) ...[
          const SizedBox(width: 8),
          Text('Reconnect',
              style: TextStyle(fontSize: 11.5, color: c.errorBannerText)),
        ],
        if (unread > 0) ...[
          const SizedBox(width: 10),
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: AppColors.notification,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text('$unread',
              style: TextStyle(fontSize: 12, color: c.textTertiary)),
        ],
      ],
    );
  }
}

/// [child] with the red notification dot on its top-right corner when [dot].
class _Dotted extends StatelessWidget {
  const _Dotted({required this.dot, required this.child});

  final bool dot;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          if (dot)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: AppColors.notification,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      );
}

/// One of the five buttons.
///
/// A click toggles the pane; on desktop a double-click on a button with a
/// [windowType] opens that window instead. The two have to be told apart by
/// waiting: a click only toggles once the double-click interval has passed
/// with no second click, or the first half of every double-click would flip
/// the pane before the window appeared.
///
/// The wait is the OS's interval ([platformDoubleClickInterval]), not a
/// [GestureDetector.onDoubleTap]. That recognizer gives up after 300 ms where
/// macOS by default allows 500, so an ordinary double-click reached the old
/// wrapper as two single taps — the pane toggled twice and no window came.
///
/// A button without a window acts on the first click and ignores a second
/// inside the interval, so a double-click on it is one toggle, not two.
class _ViewButton extends StatefulWidget {
  const _ViewButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.windowType,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onTap;

  /// The `type` the sub-window is created with, or null for a view that has
  /// no window of its own.
  final String? windowType;

  @override
  State<_ViewButton> createState() => _ViewButtonState();
}

class _ViewButtonState extends State<_ViewButton> {
  static bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Fetched once the button is on screen so a press never has to wait on
  /// the channel; Flutter's figure stands in until the answer lands.
  Duration _interval = kDoubleTapTimeout;

  /// Runs while a click is waiting to find out whether it was the first half
  /// of a double-click.
  Timer? _pending;

  /// When the last click on a windowless button landed.
  DateTime? _lastTap;

  bool get _opensWindow => widget.windowType != null && !_isMobile;

  @override
  void initState() {
    super.initState();
    platformDoubleClickInterval().then((d) {
      if (mounted) _interval = d;
    });
  }

  @override
  void dispose() {
    _pending?.cancel();
    super.dispose();
  }

  void _pressed() {
    if (!_opensWindow) {
      final now = DateTime.now();
      final last = _lastTap;
      _lastTap = now;
      if (last != null && now.difference(last) < _interval) return;
      widget.onTap();
      return;
    }

    final pending = _pending;
    if (pending != null) {
      pending.cancel();
      _pending = null;
      unawaited(showOrCreateSubWindow(widget.windowType!));
      return;
    }

    _pending = Timer(_interval, () {
      _pending = null;
      // The callback is read now, not when the click landed: the pane state
      // it closes over may have been rebuilt in the meantime.
      if (mounted) widget.onTap();
    });
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: widget.icon,
      tooltip: widget.tooltip,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints(
        minWidth: touchTarget(28),
        minHeight: touchTarget(28),
      ),
      onPressed: _pressed,
    );
  }
}
