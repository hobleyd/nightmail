import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/settings/app_settings.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/presentation/blocs/home/folder_auto_selection.dart';
import 'package:nightmail/presentation/blocs/home/home_cubit.dart';

import 'home_cubit_test.mocks.dart';

EmailFolder _folder(String id, String name) => EmailFolder(
      id: id,
      displayName: name,
      totalItemCount: 0,
      unreadItemCount: 0,
    );

@GenerateMocks([AppSettings])
void main() {
  group('HomeCubit', () {
    late MockAppSettings mockSettings;
    late HomeCubit cubit;

    setUp(() {
      mockSettings = MockAppSettings();
      cubit = HomeCubit(mockSettings);
    });

    tearDown(() => cubit.close());

    test('starts on the email view with nothing selected', () {
      expect(cubit.state.view, HomeView.email);
      expect(cubit.state.selectedFolderId, isNull);
      expect(cubit.state.selectedEmailId, isNull);
    });

    group('load', () {
      test('restores a previously saved non-email view', () async {
        when(mockSettings.loadActiveView()).thenAnswer((_) async => 'calendar');

        await cubit.load();

        expect(cubit.state.view, HomeView.calendar);
      });

      test('an unrecognised saved value falls back to email', () async {
        when(mockSettings.loadActiveView()).thenAnswer((_) async => 'garbage');

        await cubit.load();

        expect(cubit.state.view, HomeView.email);
      });

      test('does not emit at all when the saved view is already email',
          () async {
        when(mockSettings.loadActiveView()).thenAnswer((_) async => 'email');

        final states = <HomeState>[];
        final sub = cubit.stream.listen(states.add);
        await cubit.load();
        await sub.cancel();

        expect(states, isEmpty);
      });
    });

    group('per-account folder/expansion memory', () {
      test('remembers and returns the last folder per account', () {
        expect(cubit.savedFolderForAccount('acct-1'), isNull);

        cubit.rememberFolderForAccount('acct-1', 'folder-a');
        cubit.rememberFolderForAccount('acct-2', 'folder-b');

        expect(cubit.savedFolderForAccount('acct-1'), 'folder-a');
        expect(cubit.savedFolderForAccount('acct-2'), 'folder-b');
      });

      test('remembers and returns expanded folder ids per account', () {
        expect(cubit.savedExpandedForAccount('acct-1'), isEmpty);

        cubit.rememberExpandedForAccount('acct-1', {'f1', 'f2'});

        expect(cubit.savedExpandedForAccount('acct-1'), {'f1', 'f2'});
        // A defensive copy — mutating the returned set must not corrupt what
        // is remembered.
        cubit.savedExpandedForAccount('acct-1').add('f3');
        expect(cubit.savedExpandedForAccount('acct-1'), {'f1', 'f2'});
      });
    });

    group('folder/email selection', () {
      test('selectFolder sets the folder and clears the selected email', () {
        cubit.selectEmail('email-1');
        cubit.selectFolder('folder-1');

        expect(cubit.state.selectedFolderId, 'folder-1');
        expect(cubit.state.selectedEmailId, isNull);
      });

      test('clearFolder drops the folder but keeps the view and account label',
          () {
        cubit.setAccountLabel('Work');
        cubit.showCalendar();
        cubit.selectFolder('folder-1');

        cubit.clearFolder();

        expect(cubit.state.selectedFolderId, isNull);
        expect(cubit.state.view, HomeView.calendar);
        expect(cubit.state.accountLabel, 'Work');
      });

      test('selectEmail sets the email without touching the folder', () {
        cubit.selectFolder('folder-1');
        cubit.selectEmail('email-1');

        expect(cubit.state.selectedFolderId, 'folder-1');
        expect(cubit.state.selectedEmailId, 'email-1');
      });

      test('clearEmail drops only the selected email', () {
        cubit.selectFolder('folder-1');
        cubit.selectEmail('email-1');

        cubit.clearEmail();

        expect(cubit.state.selectedFolderId, 'folder-1');
        expect(cubit.state.selectedEmailId, isNull);
      });
    });

    group('notification navigation', () {
      test('openEmailFromNotification switches to the email view and stamps '
          'the notification id', () {
        cubit.showCalendar();

        cubit.openEmailFromNotification('email-9');

        expect(cubit.state.view, HomeView.email);
        expect(cubit.state.selectedEmailId, 'email-9');
        expect(cubit.state.notificationEmailId, 'email-9');
      });

      test('clearNotificationNavigation drops only the notification marker',
          () {
        cubit.openEmailFromNotification('email-9');

        cubit.clearNotificationNavigation();

        expect(cubit.state.notificationEmailId, isNull);
        expect(cubit.state.selectedEmailId, 'email-9');
      });
    });

    group('view switches persist the choice', () {
      setUp(() {
        when(mockSettings.saveActiveView(any)).thenAnswer((_) async {});
      });

      test('showCalendar', () {
        cubit.showCalendar();
        expect(cubit.state.view, HomeView.calendar);
        verify(mockSettings.saveActiveView('calendar')).called(1);
      });

      test('showTasks', () {
        cubit.showTasks();
        expect(cubit.state.view, HomeView.tasks);
        verify(mockSettings.saveActiveView('tasks')).called(1);
      });

      test('showAi', () {
        cubit.showAi();
        expect(cubit.state.view, HomeView.ai);
        verify(mockSettings.saveActiveView('ai')).called(1);
      });

      test('showEmail', () {
        cubit.showCalendar();
        cubit.showEmail();
        expect(cubit.state.view, HomeView.email);
        verify(mockSettings.saveActiveView('email')).called(1);
      });
    });

    test('setAccountLabel updates only the label', () {
      cubit.selectFolder('folder-1');
      cubit.setAccountLabel('Personal');

      expect(cubit.state.accountLabel, 'Personal');
      expect(cubit.state.selectedFolderId, 'folder-1');
    });
  });

  group('folderToAutoSelect', () {
    final inbox = _folder('inbox-id', 'Inbox');
    final archive = _folder('archive-id', 'Archive');

    test('returns null when there are no folders to select from', () {
      expect(
        folderToAutoSelect(
          folders: const [],
          selectedFolderId: null,
          selectedEmailId: null,
        ),
        isNull,
      );
    });

    test('leaves an existing folder selection alone', () {
      expect(
        folderToAutoSelect(
          folders: [inbox, archive],
          selectedFolderId: 'archive-id',
          selectedEmailId: null,
        ),
        isNull,
      );
    });

    test('does not override an email opened from a notification', () {
      expect(
        folderToAutoSelect(
          folders: [inbox, archive],
          selectedFolderId: null,
          selectedEmailId: 'email-1',
        ),
        isNull,
      );
    });

    test('prefers the account\'s last folder when it still exists', () {
      final result = folderToAutoSelect(
        folders: [inbox, archive],
        selectedFolderId: null,
        selectedEmailId: null,
        preferredFolderId: 'archive-id',
      );
      expect(result, archive);
    });

    test('falls through to Inbox when the preferred folder is gone', () {
      final result = folderToAutoSelect(
        folders: [inbox, archive],
        selectedFolderId: null,
        selectedEmailId: null,
        preferredFolderId: 'deleted-id',
      );
      expect(result, inbox);
    });

    test('matches "Inbox" case-insensitively', () {
      final lowerInbox = _folder('inbox-id', 'inbox');
      final result = folderToAutoSelect(
        folders: [archive, lowerInbox],
        selectedFolderId: null,
        selectedEmailId: null,
      );
      expect(result, lowerInbox);
    });

    test('falls back to the first folder when none is named Inbox', () {
      final result = folderToAutoSelect(
        folders: [archive],
        selectedFolderId: null,
        selectedEmailId: null,
      );
      expect(result, archive);
    });
  });
}
