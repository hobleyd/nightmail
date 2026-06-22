import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get_it/get_it.dart';

import 'core/config/oauth_client_id_storage.dart';
import 'core/settings/app_settings.dart';
import 'data/database/app_database.dart';
import 'data/datasources/local/delta_token_datasource.dart';
import 'data/datasources/local/email_local_datasource.dart';
import 'data/datasources/local/email_local_datasource_impl.dart';
import 'data/datasources/local/folder_local_datasource.dart';
import 'data/datasources/local/sender_local_datasource.dart';
import 'data/datasources/local/sender_local_datasource_impl.dart';
import 'data/repositories/calendar_repository_impl.dart';
import 'data/repositories/directory_contacts_repository_impl.dart';
import 'data/repositories/email_repository_impl.dart';
import 'data/repositories/sender_repository_impl.dart';
import 'data/repositories/spam_filter_repository_impl.dart';
import 'data/repositories/system_contacts_repository_impl.dart';
import 'data/repositories/tasks_repository_impl.dart';
import 'data/services/eml_parser.dart';
import 'domain/repositories/calendar_repository.dart';
import 'domain/repositories/directory_contacts_repository.dart';
import 'domain/repositories/email_repository.dart';
import 'domain/repositories/sender_repository.dart';
import 'domain/repositories/spam_filter_repository.dart';
import 'domain/repositories/system_contacts_repository.dart';
import 'domain/repositories/tasks_repository.dart';
import 'domain/usecases/attach_email_to_task.dart';
import 'domain/usecases/check_sender_anomaly.dart';
import 'domain/usecases/merge_sender_addresses.dart';
import 'domain/usecases/cancel_calendar_event.dart';
import 'domain/usecases/check_attendees_availability.dart';
import 'domain/usecases/create_calendar_event.dart';
import 'domain/usecases/decline_calendar_event.dart';
import 'domain/usecases/create_task.dart';
import 'domain/usecases/delete_email.dart';
import 'domain/usecases/report_junk.dart';
import 'domain/usecases/classify_emails.dart';
import 'domain/usecases/train_spam_filter.dart';
import 'domain/usecases/download_task_attachment.dart';
import 'domain/usecases/move_email.dart';
import 'domain/usecases/download_attachment.dart';
import 'domain/usecases/create_folder.dart';
import 'domain/usecases/empty_folder.dart';
import 'domain/usecases/get_calendar_events.dart';
import 'domain/usecases/get_email.dart';
import 'domain/usecases/get_emails.dart';
import 'domain/usecases/get_mail_folders.dart';
import 'domain/usecases/get_task_attachments.dart';
import 'domain/usecases/get_task_lists.dart';
import 'domain/usecases/get_tasks.dart';
import 'domain/usecases/mark_email_as_read.dart';
import 'domain/usecases/record_known_senders.dart';
import 'domain/usecases/search_contacts.dart';
import 'domain/usecases/delete_server_draft.dart';
import 'domain/usecases/save_server_draft.dart';
import 'domain/usecases/search_emails.dart';
import 'domain/usecases/send_email.dart';
import 'domain/usecases/propose_new_time.dart';
import 'domain/usecases/cancel_meeting_from_email.dart';
import 'domain/usecases/remove_cancelled_meeting.dart';
import 'domain/usecases/respond_to_meeting_invite.dart';
import 'domain/usecases/update_calendar_event.dart';
import 'domain/usecases/update_task_due_date.dart';
import 'domain/usecases/update_task_status.dart';
import 'domain/usecases/get_cached_emails.dart';
import 'domain/usecases/get_cached_folders.dart';
import 'infrastructure/accounts/account_manager.dart';
import 'infrastructure/accounts/account_storage.dart';
import 'infrastructure/badge/badge_service.dart';
import 'infrastructure/cache/cache_encryption_service.dart';
import 'infrastructure/notifications/notification_service.dart';
import 'presentation/blocs/account/account_cubit.dart';
import 'presentation/blocs/calendar/calendar_bloc.dart';
import 'presentation/blocs/compose/compose_bloc.dart';
import 'presentation/blocs/event_edit/event_edit_bloc.dart';
import 'presentation/blocs/email_detail/email_detail_bloc.dart';
import 'presentation/blocs/email_list/email_list_bloc.dart';
import 'presentation/blocs/folder_list/folder_list_bloc.dart';
import 'presentation/blocs/mail_poller/mail_poller_cubit.dart';
import 'presentation/blocs/tasks/tasks_bloc.dart';
import 'presentation/blocs/theme/theme_cubit.dart';

final sl = GetIt.instance;

Future<void> configureDependencies() async {
  // Infrastructure — storage
  sl.registerLazySingleton<FlutterSecureStorage>(
    () => FlutterSecureStorage(
      aOptions: const AndroidOptions(encryptedSharedPreferences: true),
      // Debug/profile builds are non-sandboxed and have no provisioning profile,
      // so kSecUseDataProtectionKeychain would fail with -34018. Release builds
      // have the sandbox + keychain-access-groups entitlement so can use it.
      mOptions: MacOsOptions(usesDataProtectionKeychain: kReleaseMode),
    ),
  );

  sl.registerLazySingleton<AccountStorage>(
    () => AccountStorage(sl<FlutterSecureStorage>()),
  );

  sl.registerLazySingleton<OAuthClientIdStorage>(
    () => OAuthClientIdStorage(sl<FlutterSecureStorage>()),
  );

  sl.registerLazySingleton<AccountManager>(
    () => AccountManager(
      accountStorage: sl<AccountStorage>(),
      secureStorage: sl<FlutterSecureStorage>(),
      clientIdStorage: sl<OAuthClientIdStorage>(),
    ),
  );

  // Infrastructure — cache encryption key (generated once, stored in secure storage).
  // Initialization is deferred — CacheEncryptionService self-initializes on first use.
  sl.registerLazySingleton<CacheEncryptionService>(
    () => CacheEncryptionService(sl<FlutterSecureStorage>()),
  );

  // Data — local cache (drift opens the SQLite file lazily on first query)
  sl.registerLazySingleton<AppDatabase>(() => AppDatabase());
  sl.registerLazySingleton<DeltaTokenDatasource>(() => sl<AppDatabase>());
  sl.registerLazySingleton<FolderLocalDatasource>(() => sl<AppDatabase>());
  sl.registerLazySingleton<EmailLocalDatasource>(
    () => EmailLocalDatasourceImpl(
      database: sl<AppDatabase>(),
      encryption: sl<CacheEncryptionService>(),
    ),
  );
  sl.registerLazySingleton<SenderLocalDatasource>(
    () => SenderLocalDatasourceImpl(database: sl<AppDatabase>()),
  );

  // Data — repositories delegate to AccountManager for the live active datasource.
  sl.registerLazySingleton<EmailRepository>(
    () => EmailRepositoryImpl(
      accountManager: sl<AccountManager>(),
      localDatasource: sl<EmailLocalDatasource>(),
      folderLocalDatasource: sl<FolderLocalDatasource>(),
    ),
  );
  sl.registerLazySingleton<SenderRepository>(
    () => SenderRepositoryImpl(localDatasource: sl<SenderLocalDatasource>()),
  );
  sl.registerLazySingleton<SystemContactsRepository>(
    () => SystemContactsRepositoryImpl(),
  );
  sl.registerLazySingleton<DirectoryContactsRepository>(
    () => DirectoryContactsRepositoryImpl(accountManager: sl<AccountManager>()),
  );
  sl.registerLazySingleton<CalendarRepository>(
    () => CalendarRepositoryImpl(accountManager: sl<AccountManager>()),
  );
  sl.registerLazySingleton<TasksRepository>(
    () => TasksRepositoryImpl(accountManager: sl<AccountManager>()),
  );
  sl.registerLazySingleton<SpamFilterRepository>(
    () => SpamFilterRepositoryImpl(),
  );

  // Domain — use cases
  sl.registerLazySingleton(() => GetEmails(sl<EmailRepository>()));
  sl.registerLazySingleton(() => SearchEmails(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetEmail(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetMailFolders(sl<EmailRepository>()));
  sl.registerLazySingleton(() => MarkEmailAsRead(sl<EmailRepository>()));
  sl.registerLazySingleton(() => SendEmail(sl<EmailRepository>()));
  sl.registerLazySingleton(() => SaveServerDraft(sl<EmailRepository>()));
  sl.registerLazySingleton(() => DeleteServerDraft(sl<EmailRepository>()));
  sl.registerLazySingleton(() => MoveEmail(sl<EmailRepository>()));
  sl.registerLazySingleton(() => ReportJunk(sl<EmailRepository>()));
  sl.registerLazySingleton(() => ClassifyEmails(sl<SpamFilterRepository>()));
  sl.registerLazySingleton(() => TrainSpamFilter(sl<SpamFilterRepository>()));
  sl.registerLazySingleton(() => DeleteEmail(sl<EmailRepository>()));
  sl.registerLazySingleton(() => EmptyFolder(sl<EmailRepository>()));
  sl.registerLazySingleton(() => CreateFolder(sl<EmailRepository>()));
  sl.registerLazySingleton(() => DownloadAttachment(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetCachedEmails(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetCachedFolders(sl<EmailRepository>()));
  sl.registerLazySingleton(() => RecordKnownSenders(sl<SenderRepository>()));
  sl.registerLazySingleton(() => CheckSenderAnomaly(sl<SenderRepository>()));
  sl.registerLazySingleton(() => MergeSenderAddresses(sl<SenderRepository>()));
  sl.registerLazySingleton(() => SearchContacts(
        senderRepository: sl<SenderRepository>(),
        systemContactsRepository: sl<SystemContactsRepository>(),
        directoryContactsRepository: sl<DirectoryContactsRepository>(),
      ));
  sl.registerLazySingleton(() => GetCalendarEvents(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => CreateCalendarEvent(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => UpdateCalendarEvent(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => CheckAttendeesAvailability(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => RespondToMeetingInvite(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => RemoveCancelledMeeting(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => CancelMeetingFromEmail(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => CancelCalendarEvent(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => DeclineCalendarEvent(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => ProposeNewTime(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => EmlParser());
  sl.registerLazySingleton(() => GetTaskLists(sl<TasksRepository>()));
  sl.registerLazySingleton(() => GetTasks(sl<TasksRepository>()));
  sl.registerLazySingleton(() => CreateTask(sl<TasksRepository>()));
  sl.registerLazySingleton(() => UpdateTaskStatus(sl<TasksRepository>()));
  sl.registerLazySingleton(() => UpdateTaskDueDate(sl<TasksRepository>()));
  sl.registerLazySingleton(
    () => AttachEmailToTask(sl<EmailRepository>(), sl<TasksRepository>()),
  );
  sl.registerLazySingleton(() => GetTaskAttachments(sl<TasksRepository>()));
  sl.registerLazySingleton(() => DownloadTaskAttachment(sl<TasksRepository>()));

  // Settings
  sl.registerLazySingleton(() => AppSettings());
  sl.registerLazySingleton(() => BadgeService());
  sl.registerLazySingleton(() => NotificationService());

  // Presentation — singletons
  sl.registerLazySingleton(() => ThemeCubit());
  sl.registerLazySingleton(
    () => AccountCubit(
      accountManager: sl<AccountManager>(),
      emailRepository: sl<EmailRepository>(),
    ),
  );
  sl.registerLazySingleton(
    () => MailPollerCubit(
      accountManager: sl<AccountManager>(),
      appSettings: sl<AppSettings>(),
      badgeService: sl<BadgeService>(),
      database: sl<DeltaTokenDatasource>(),
      getCachedFolders: sl<GetCachedFolders>(),
    ),
  );

  // Presentation — BLoC factories
  sl.registerFactory(
    () => FolderListBloc(
      getMailFolders: sl<GetMailFolders>(),
      getCachedFolders: sl<GetCachedFolders>(),
      createFolder: sl<CreateFolder>(),
      accountManager: sl<AccountManager>(),
    ),
  );
  sl.registerFactory(() => EmailListBloc(
        getEmails: sl<GetEmails>(),
        getCachedEmails: sl<GetCachedEmails>(),
        markEmailAsRead: sl<MarkEmailAsRead>(),
        moveEmail: sl<MoveEmail>(),
        reportJunk: sl<ReportJunk>(),
        deleteEmail: sl<DeleteEmail>(),
        emptyFolder: sl<EmptyFolder>(),
        accountManager: sl<AccountManager>(),
        recordKnownSenders: sl<RecordKnownSenders>(),
        classifyEmails: sl<ClassifyEmails>(),
        trainSpamFilter: sl<TrainSpamFilter>(),
        searchEmails: sl<SearchEmails>(),
      ));
  sl.registerFactory(() => EmailDetailBloc(
        getEmail: sl<GetEmail>(),
        emlParser: sl<EmlParser>(),
        checkSenderAnomaly: sl<CheckSenderAnomaly>(),
        mergeSenderAddresses: sl<MergeSenderAddresses>(),
        accountManager: sl<AccountManager>(),
      ));
  sl.registerFactory(
    () => CalendarBloc(
          getCalendarEvents: sl<GetCalendarEvents>(),
          cancelCalendarEvent: sl<CancelCalendarEvent>(),
          declineCalendarEvent: sl<DeclineCalendarEvent>(),
          proposeNewTime: sl<ProposeNewTime>(),
          updateCalendarEvent: sl<UpdateCalendarEvent>(),
        ),
  );
  sl.registerFactory(() => ComposeBloc(sendEmail: sl<SendEmail>()));
  sl.registerFactory(() => TasksBloc(
        getTaskLists: sl<GetTaskLists>(),
        getTasks: sl<GetTasks>(),
        createTask: sl<CreateTask>(),
        updateTaskStatus: sl<UpdateTaskStatus>(),
        updateTaskDueDate: sl<UpdateTaskDueDate>(),
        attachEmailToTask: sl<AttachEmailToTask>(),
        getTaskAttachments: sl<GetTaskAttachments>(),
        downloadTaskAttachment: sl<DownloadTaskAttachment>(),
      ));
  sl.registerFactory(() => EventEditBloc(
        createCalendarEvent: sl<CreateCalendarEvent>(),
        updateCalendarEvent: sl<UpdateCalendarEvent>(),
        notificationService: sl<NotificationService>(),
      ));
}
