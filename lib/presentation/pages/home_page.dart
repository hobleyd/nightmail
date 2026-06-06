import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../injection_container.dart';
import '../blocs/auth/auth_bloc.dart';
import '../blocs/auth/auth_event.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/folder_list/folder_list_bloc.dart';
import '../blocs/folder_list/folder_list_event.dart';
import '../blocs/folder_list/folder_list_state.dart';
import '../blocs/home/home_cubit.dart';
import '../widgets/email_list_panel.dart';
import '../widgets/folder_panel.dart';
import '../widgets/reading_pane.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) =>
              sl<FolderListBloc>()..add(const FolderListLoadRequested()),
        ),
        BlocProvider(create: (_) => sl<EmailListBloc>()),
        BlocProvider(create: (_) => sl<EmailDetailBloc>()),
        BlocProvider(create: (_) => HomeCubit()),
      ],
      child: const _HomeView(),
    );
  }
}

class _HomeView extends StatelessWidget {
  const _HomeView();

  @override
  Widget build(BuildContext context) {
    // When folders finish loading, auto-select Inbox and load its emails.
    return BlocListener<FolderListBloc, FolderListState>(
      listenWhen: (prev, curr) =>
          prev is! FolderListLoaded && curr is FolderListLoaded,
      listener: (context, state) {
        if (state is FolderListLoaded) {
          final homeCubit = context.read<HomeCubit>();
          if (homeCubit.state.selectedFolderId != null) return;

          final inbox = state.folders.firstWhere(
            (f) => f.displayName.toLowerCase() == 'inbox',
            orElse: () => state.folders.first,
          );

          homeCubit.selectFolder(inbox.id);
          context.read<EmailListBloc>().add(
                EmailListLoadRequested(folderId: inbox.id),
              );
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F1117),
        body: Column(
          children: [
            _AppBar(),
            Expanded(child: _ThreePanelLayout()),
          ],
        ),
      ),
    );
  }
}

class _AppBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      color: const Color(0xFF0F1117),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.logout_rounded,
                size: 18, color: Color(0xFF4B5563)),
            tooltip: 'Sign out',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () =>
                context.read<AuthBloc>().add(const AuthSignOutRequested()),
          ),
        ],
      ),
    );
  }
}

class _ThreePanelLayout extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return BlocBuilder<HomeCubit, HomeState>(
      builder: (context, homeState) {
        final selectedFolder = _resolveSelectedFolder(context, homeState);

        return Row(
          children: [
            // Panel 1 — Folders (fixed 220px)
            SizedBox(
              width: 220,
              child: FolderPanel(
                selectedFolderId: homeState.selectedFolderId,
                onFolderSelected: (folder) {
                  context.read<HomeCubit>().selectFolder(folder.id);
                  context.read<EmailDetailBloc>().add(const EmailDetailCleared());
                  context.read<EmailListBloc>().add(
                        EmailListLoadRequested(folderId: folder.id),
                      );
                },
              ),
            ),
            const VerticalDivider(
                width: 1, thickness: 1, color: Color(0xFF1E2130)),
            // Panel 2 — Email list (fixed 320px)
            SizedBox(
              width: 320,
              child: EmailListPanel(
                folderName: selectedFolder,
                selectedEmailId: homeState.selectedEmailId,
                onEmailSelected: (email) {
                  context.read<HomeCubit>().selectEmail(email.id);
                  context.read<EmailDetailBloc>().add(
                        EmailDetailLoadRequested(emailId: email.id),
                      );
                  if (!email.isRead) {
                    context.read<EmailListBloc>().add(
                          EmailListMarkReadRequested(
                              emailId: email.id, isRead: true),
                        );
                  }
                },
              ),
            ),
            const VerticalDivider(
                width: 1, thickness: 1, color: Color(0xFF1E2130)),
            // Panel 3 — Reading pane (flex)
            const Expanded(child: ReadingPane()),
          ],
        );
      },
    );
  }

  String _resolveSelectedFolder(BuildContext context, HomeState homeState) {
    if (homeState.selectedFolderId == null) return 'Inbox';
    final folderState = context.read<FolderListBloc>().state;
    if (folderState is FolderListLoaded) {
      try {
        return folderState.folders
            .firstWhere((f) => f.id == homeState.selectedFolderId)
            .displayName;
      } catch (_) {}
    }
    return 'Inbox';
  }
}
