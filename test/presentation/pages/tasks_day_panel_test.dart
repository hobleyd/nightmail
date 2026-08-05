import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:nightmail/domain/usecases/attach_email_to_task.dart';
import 'package:nightmail/domain/usecases/create_task.dart';
import 'package:nightmail/domain/usecases/download_task_attachment.dart';
import 'package:nightmail/domain/usecases/get_task_attachments.dart';
import 'package:nightmail/domain/usecases/get_task_lists.dart';
import 'package:nightmail/domain/usecases/get_tasks.dart';
import 'package:nightmail/domain/usecases/update_task_due_date.dart';
import 'package:nightmail/domain/usecases/update_task_status.dart';
import 'package:nightmail/infrastructure/notifications/task_reminder_service.dart';
import 'package:nightmail/presentation/blocs/tasks/tasks_bloc.dart';
import 'package:nightmail/presentation/pages/tasks_page.dart';

import 'tasks_day_panel_test.mocks.dart';

// The panel is never sent an event here, so the bloc stays in TasksInitial and
// none of these are actually called — they exist only to build it.
@GenerateNiceMocks([
  MockSpec<GetTaskLists>(),
  MockSpec<GetTasks>(),
  MockSpec<CreateTask>(),
  MockSpec<UpdateTaskStatus>(),
  MockSpec<UpdateTaskDueDate>(),
  MockSpec<AttachEmailToTask>(),
  MockSpec<GetTaskAttachments>(),
  MockSpec<DownloadTaskAttachment>(),
  MockSpec<TaskReminderService>(),
])
void main() {
  late TasksBloc bloc;
  late int closes;

  setUp(() {
    closes = 0;
    bloc = TasksBloc(
      getTaskLists: MockGetTaskLists(),
      getTasks: MockGetTasks(),
      createTask: MockCreateTask(),
      updateTaskStatus: MockUpdateTaskStatus(),
      updateTaskDueDate: MockUpdateTaskDueDate(),
      attachEmailToTask: MockAttachEmailToTask(),
      getTaskAttachments: MockGetTaskAttachments(),
      downloadTaskAttachment: MockDownloadTaskAttachment(),
      taskReminders: MockTaskReminderService(),
    );
  });

  tearDown(() => bloc.close());

  Future<void> pumpPanel(
    WidgetTester tester, {
    required bool useBackNavigation,
    Size? surfaceSize,
  }) async {
    if (surfaceSize != null) {
      await tester.binding.setSurfaceSize(surfaceSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlocProvider.value(
          value: bloc,
          child: TasksDayPanel(
            onClose: () => closes++,
            useBackNavigation: useBackNavigation,
          ),
        ),
      ),
    ));
  }

  group('TasksDayPanel — dismiss affordance', () {
    testWidgets('docked as a side pane it closes with a trailing X',
        (tester) async {
      await pumpPanel(tester, useBackNavigation: false);

      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
    });

    testWidgets('pushed as a route it closes with a leading back arrow',
        (tester) async {
      // The mobile shell pushes the panel, so it belongs in the same back
      // navigation idiom as the reading pane rather than carrying a close box.
      await pumpPanel(tester, useBackNavigation: true);

      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('the back arrow reports the same dismissal as the X',
        (tester) async {
      await pumpPanel(tester, useBackNavigation: true);

      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pump();

      expect(closes, 1);
    });

    testWidgets('the back arrow leads the header, ahead of the title',
        (tester) async {
      await pumpPanel(tester, useBackNavigation: true);

      final arrow = tester
          .getTopLeft(find.byIcon(Icons.arrow_back_ios_new_rounded))
          .dx;
      expect(arrow, lessThan(tester.getTopLeft(find.text('Tasks')).dx));
    });
  });

  group('TasksDayPanel — touch metrics', () {
    // The header icon and the empty-state illustration share a glyph; the
    // header's is the first in the tree.
    double headerIconSize(WidgetTester tester) =>
        tester.widget<Icon>(find.byIcon(Icons.checklist_rounded).first).size!;

    testWidgets('doubles the header icon on a touch platform', (tester) async {
      // Widget tests report android by default, so pin both sides explicitly.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpPanel(tester, useBackNavigation: false);
      final onDesktop = headerIconSize(tester);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pumpPanel(tester, useBackNavigation: true);
      final onTouch = headerIconSize(tester);

      // Reset inside the body: the binding checks for leaked foundation debug
      // variables before tearDown runs.
      debugDefaultTargetPlatformOverride = null;
      expect(onTouch, onDesktop * 2);
    });

    testWidgets('the enlarged header still fits the narrowest phone',
        (tester) async {
      // 320 x 568 is the smallest screen worth supporting; the flat 48 px tap
      // target exists so a row of these does not overflow it.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pumpPanel(
        tester,
        useBackNavigation: true,
        surfaceSize: const Size(320, 568),
      );
      final overflow = tester.takeException();

      debugDefaultTargetPlatformOverride = null;
      expect(overflow, isNull);
    });
  });
}
