import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/ai/ai_folder_cubit.dart';
import '../blocs/email_list/email_list_event.dart' show EmailListResultSet;
import 'ai/agent_chat_panel.dart';
import 'ai/tool_call_card.dart';

/// The main window's folder assistant: an [AgentChatPanel] over the
/// [AiFolderCubit] in scope, whose turns run against the current folder.
class AiDayPanel extends StatelessWidget {
  const AiDayPanel({
    super.key,
    required this.onClose,
    this.folderIdProvider,
    this.accountIdProvider,
    this.contextProvider,
    this.onShowInList,
    this.useBackNavigation = false,
  });

  final VoidCallback onClose;

  /// True when the panel was pushed as a route rather than docked as a side
  /// pane — the mobile shell. It then dismisses through a leading back arrow,
  /// like the reading pane, instead of a trailing close button.
  final bool useBackNavigation;

  /// Called just before each turn to resolve the current folder's id, which the
  /// agent's tools default to. Returns null when no folder is selected.
  final String? Function()? folderIdProvider;

  /// Called alongside [folderIdProvider]: the account that folder belongs to.
  final String? Function()? accountIdProvider;

  /// Shows a search card's results in the email list; null hides the action.
  final ValueChanged<EmailListResultSet>? onShowInList;

  /// Called just before each turn to collect the fallback context string (a
  /// formatted excerpt of the current folder's emails). Used only when the
  /// routed model lacks tool calling. Returns null when no context is available.
  final String? Function()? contextProvider;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<AiFolderCubit>();
    return AgentChatPanel(
      cubit: cubit,
      onClose: onClose,
      useBackNavigation: useBackNavigation,
      welcomeTitle: 'Ask about this folder — I can read and search your mail.',
      hintText: 'Ask about your mail…',
      onSend: (instruction) => cubit.send(
        instruction,
        currentFolderId: folderIdProvider?.call(),
        accountId: accountIdProvider?.call(),
        fallbackEmailsContext: contextProvider?.call(),
      ),
      toolCardBuilder: (item) =>
          ToolCallCard(item: item, onShowInList: onShowInList),
    );
  }
}
