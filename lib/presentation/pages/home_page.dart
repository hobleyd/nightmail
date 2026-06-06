import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
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
        backgroundColor: context.colors.surfaceBase,
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
    final c = context.colors;
    return Container(
      height: 48,
      color: c.surfaceBase,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Spacer(),
          IconButton(
            icon: Icon(Icons.logout_rounded, size: 18, color: c.textDimmed),
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

class _ThreePanelLayout extends StatefulWidget {
  @override
  State<_ThreePanelLayout> createState() => _ThreePanelLayoutState();
}

class _ThreePanelLayoutState extends State<_ThreePanelLayout> {
  double _folderWidth = 220;
  double _emailListWidth = 320;

  static const double _minPanelWidth = 120;
  static const double _minReadingPaneWidth = 200;
  static const double _handleWidth = 8;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<HomeCubit, HomeState>(
      builder: (context, homeState) {
        final selectedFolder = _resolveSelectedFolder(context, homeState);

        return LayoutBuilder(
          builder: (context, constraints) {
            final totalWidth = constraints.maxWidth;
            const totalHandleWidth = _handleWidth * 2;

            return Row(
              children: [
                // Panel 1 — Folders
                SizedBox(
                  width: _folderWidth,
                  child: FolderPanel(
                    selectedFolderId: homeState.selectedFolderId,
                    onFolderSelected: (folder) {
                      context.read<HomeCubit>().selectFolder(folder.id);
                      context
                          .read<EmailDetailBloc>()
                          .add(const EmailDetailCleared());
                      context.read<EmailListBloc>().add(
                            EmailListLoadRequested(folderId: folder.id),
                          );
                    },
                  ),
                ),
                _ResizeHandle(
                  onDrag: (delta) {
                    setState(() {
                      final maxWidth = totalWidth -
                          totalHandleWidth -
                          _emailListWidth -
                          _minReadingPaneWidth;
                      _folderWidth =
                          (_folderWidth + delta).clamp(_minPanelWidth, maxWidth);
                    });
                  },
                ),
                // Panel 2 — Email list
                SizedBox(
                  width: _emailListWidth,
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
                _ResizeHandle(
                  onDrag: (delta) {
                    setState(() {
                      final maxWidth = totalWidth -
                          totalHandleWidth -
                          _folderWidth -
                          _minReadingPaneWidth;
                      _emailListWidth = (_emailListWidth + delta)
                          .clamp(_minPanelWidth, maxWidth);
                    });
                  },
                ),
                // Panel 3 — Reading pane (flex)
                const Expanded(child: ReadingPane()),
              ],
            );
          },
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

class _ResizeHandle extends StatefulWidget {
  final ValueChanged<double> onDrag;

  const _ResizeHandle({required this.onDrag});

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(
              width: 1,
              color: _hovered
                  ? context.colors.textDimmed
                  : context.colors.separator,
            ),
          ),
        ),
      ),
    );
  }
}
