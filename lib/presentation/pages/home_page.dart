import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email_folder.dart';
import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/calendar/calendar_bloc.dart';
import '../blocs/calendar/calendar_event.dart';
import '../blocs/tasks/tasks_bloc.dart';
import '../blocs/tasks/tasks_event.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/folder_list/folder_list_bloc.dart';
import '../blocs/folder_list/folder_list_event.dart';
import '../blocs/folder_list/folder_list_state.dart';
import '../blocs/home/home_cubit.dart';
import '../blocs/mail_poller/mail_poller_cubit.dart';
import '../widgets/email_list_panel.dart';
import '../widgets/folder_panel.dart';
import '../widgets/reading_pane.dart';
import 'calendar_page.dart';
import 'tasks_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: sl<AccountCubit>()),
        BlocProvider.value(
          value: sl<MailPollerCubit>()..initialize(),
        ),
        BlocProvider(
          create: (_) =>
              sl<FolderListBloc>()..add(const FolderListLoadRequested()),
        ),
        BlocProvider(create: (_) => sl<EmailListBloc>()),
        BlocProvider(create: (_) => sl<EmailDetailBloc>()),
        BlocProvider(create: (_) => HomeCubit()),
        BlocProvider(create: (_) => sl<CalendarBloc>()),
        BlocProvider(
          create: (_) =>
              sl<TasksBloc>()..add(const TasksLoadRequested()),
        ),
      ],
      child: const _HomeView(),
    );
  }
}

class _HomeView extends StatelessWidget {
  const _HomeView();

  @override
  Widget build(BuildContext context) {
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
        body: const _ThreePanelLayout(),
      ),
    );
  }
}

class _ThreePanelLayout extends StatefulWidget {
  const _ThreePanelLayout();

  @override
  State<_ThreePanelLayout> createState() => _ThreePanelLayoutState();
}

class _ThreePanelLayoutState extends State<_ThreePanelLayout> {
  double _folderWidth = 220;
  double _emailListWidth = 320;
  double _calendarPaneWidth = 300;

  static const double _minPanelWidth = 120;
  static const double _minReadingPaneWidth = 200;
  static const double _minCalendarPaneWidth = 200;
  static const double _handleWidth = 8;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<HomeCubit, HomeState>(
      builder: (context, homeState) {
        return BlocBuilder<FolderListBloc, FolderListState>(
          builder: (context, folderListState) {
            return _buildLayout(context, homeState, folderListState);
          },
        );
      },
    );
  }

  Widget _buildLayout(
    BuildContext context,
    HomeState homeState,
    FolderListState folderListState,
  ) {
    final selectedFolder = _resolveFolder(homeState, folderListState);

    return LayoutBuilder(
          builder: (context, constraints) {
            final totalWidth = constraints.maxWidth;
            const totalHandleWidth = _handleWidth * 2;

            final accountState = context.read<AccountCubit>().state;
            final accountId = accountState is AccountsLoaded
                ? accountState.activeAccount.id
                : '';
            final homeCubit = context.read<HomeCubit>();

            final folderPanel = FolderPanel(
              key: ValueKey(accountId),
              selectedFolderId: homeState.selectedFolderId,
              initialExpandedIds: homeCubit.savedExpandedForAccount(accountId),
              onExpandedIdsChanged: (ids) {
                final state = context.read<AccountCubit>().state;
                if (state is AccountsLoaded) {
                  homeCubit.rememberExpandedForAccount(
                      state.activeAccount.id, ids);
                }
              },
              onFolderSelected: (folder) {
                homeCubit.selectFolder(folder.id);
                context.read<EmailDetailBloc>().add(const EmailDetailCleared());
                context.read<EmailListBloc>().add(
                      EmailListLoadRequested(folderId: folder.id),
                    );
              },
              onCalendarTapped: () {
                if (homeState.view == HomeView.calendar) {
                  homeCubit.showEmail();
                } else {
                  homeCubit.showCalendar();
                  final monday = _mondayOfWeek(DateTime.now());
                  context.read<CalendarBloc>().add(
                        CalendarWeekLoadRequested(weekStart: monday),
                      );
                }
              },
              onTasksTapped: () {
                if (homeState.view == HomeView.tasks) {
                  homeCubit.showEmail();
                } else {
                  homeCubit.showTasks();
                }
              },
            );

            if (homeState.view == HomeView.tasks) {
              return Row(
                children: [
                  SizedBox(width: _folderWidth, child: folderPanel),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _emailListWidth -
                            _minReadingPaneWidth -
                            _calendarPaneWidth;
                        _folderWidth =
                            (_folderWidth + delta).clamp(_minPanelWidth, max);
                      });
                    },
                  ),
                  SizedBox(
                    width: _emailListWidth,
                    child: EmailListPanel(
                      folderName: selectedFolder?.displayName ?? 'Inbox',
                      folder: selectedFolder,
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
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _folderWidth -
                            _minReadingPaneWidth -
                            _calendarPaneWidth;
                        _emailListWidth =
                            (_emailListWidth + delta).clamp(_minPanelWidth, max);
                      });
                    },
                  ),
                  const Expanded(child: ReadingPane()),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _folderWidth -
                            _emailListWidth -
                            _minReadingPaneWidth;
                        _calendarPaneWidth = (_calendarPaneWidth - delta)
                            .clamp(_minCalendarPaneWidth, max);
                      });
                    },
                  ),
                  SizedBox(
                    width: _calendarPaneWidth,
                    child: TasksDayPanel(
                      onClose: () => context.read<HomeCubit>().showEmail(),
                    ),
                  ),
                ],
              );
            }

            if (homeState.view == HomeView.calendar) {
              return Row(
                children: [
                  SizedBox(width: _folderWidth, child: folderPanel),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _emailListWidth -
                            _minReadingPaneWidth -
                            _calendarPaneWidth;
                        _folderWidth =
                            (_folderWidth + delta).clamp(_minPanelWidth, max);
                      });
                    },
                  ),
                  SizedBox(
                    width: _emailListWidth,
                    child: EmailListPanel(
                      folderName: selectedFolder?.displayName ?? 'Inbox',
                      folder: selectedFolder,
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
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _folderWidth -
                            _minReadingPaneWidth -
                            _calendarPaneWidth;
                        _emailListWidth =
                            (_emailListWidth + delta).clamp(_minPanelWidth, max);
                      });
                    },
                  ),
                  const Expanded(child: ReadingPane()),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _folderWidth -
                            _emailListWidth -
                            _minReadingPaneWidth;
                        _calendarPaneWidth = (_calendarPaneWidth - delta)
                            .clamp(_minCalendarPaneWidth, max);
                      });
                    },
                  ),
                  SizedBox(
                    width: _calendarPaneWidth,
                    child: CalendarDayPanel(
                      onClose: () =>
                          context.read<HomeCubit>().showEmail(),
                    ),
                  ),
                ],
              );
            }

            return Row(
              children: [
                SizedBox(width: _folderWidth, child: folderPanel),
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
                SizedBox(
                  width: _emailListWidth,
                  child: EmailListPanel(
                    folderName: selectedFolder?.displayName ?? 'Inbox',
                    folder: selectedFolder,
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
                const Expanded(child: ReadingPane()),
              ],
            );
          },
        );
  }

  static DateTime _mondayOfWeek(DateTime date) {
    final daysFromMonday = (date.weekday - 1) % 7;
    return DateTime(date.year, date.month, date.day - daysFromMonday);
  }

  EmailFolder? _resolveFolder(HomeState homeState, FolderListState folderListState) {
    if (homeState.selectedFolderId == null) return null;
    if (folderListState is FolderListLoaded) {
      try {
        return folderListState.folders
            .firstWhere((f) => f.id == homeState.selectedFolderId);
      } catch (_) {}
    }
    return null;
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
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerMove: (event) => widget.onDrag(event.delta.dx),
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
