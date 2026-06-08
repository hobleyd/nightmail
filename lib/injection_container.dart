import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get_it/get_it.dart';

import 'core/settings/app_settings.dart';
import 'data/database/app_database.dart';
import 'data/datasources/local/email_local_datasource.dart';
import 'data/datasources/local/email_local_datasource_impl.dart';
import 'data/repositories/calendar_repository_impl.dart';
import 'data/repositories/email_repository_impl.dart';
import 'data/repositories/tasks_repository_impl.dart';
import 'domain/repositories/calendar_repository.dart';
import 'domain/repositories/email_repository.dart';
import 'domain/repositories/tasks_repository.dart';
import 'domain/usecases/create_calendar_event.dart';
import 'domain/usecases/create_task.dart';
import 'domain/usecases/delete_email.dart';
import 'domain/usecases/move_email.dart';
import 'domain/usecases/download_attachment.dart';
import 'domain/usecases/empty_folder.dart';
import 'domain/usecases/get_calendar_events.dart';
import 'domain/usecases/get_email.dart';
import 'domain/usecases/get_emails.dart';
import 'domain/usecases/get_mail_folders.dart';
import 'domain/usecases/get_task_lists.dart';
import 'domain/usecases/get_tasks.dart';
import 'domain/usecases/mark_email_as_read.dart';
import 'domain/usecases/send_email.dart';
import 'domain/usecases/update_calendar_event.dart';
import 'domain/usecases/update_task_status.dart';
import 'domain/usecases/get_cached_emails.dart';
import 'infrastructure/accounts/account_manager.dart';
import 'infrastructure/accounts/account_storage.dart';
import 'infrastructure/badge/badge_service.dart';
import 'infrastructure/cache/cache_encryption_service.dart';
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
    () => const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    ),
  );

  sl.registerLazySingleton<AccountStorage>(
    () => AccountStorage(sl<FlutterSecureStorage>()),
  );

  sl.registerLazySingleton<AccountManager>(
    () => AccountManager(
      accountStorage: sl<AccountStorage>(),
      secureStorage: sl<FlutterSecureStorage>(),
    ),
  );

  // Initialize AccountManager — loads persisted accounts and runs legacy migration.
  await sl<AccountManager>().initialize();

  // Infrastructure — cache encryption key (generated once, stored in secure storage)
  sl.registerLazySingleton<CacheEncryptionService>(
    () => CacheEncryptionService(sl<FlutterSecureStorage>()),
  );
  await sl<CacheEncryptionService>().initialize();

  // Data — local cache (drift opens the SQLite file lazily on first query)
  sl.registerLazySingleton<AppDatabase>(() => AppDatabase());
  sl.registerLazySingleton<EmailLocalDatasource>(
    () => EmailLocalDatasourceImpl(
      database: sl<AppDatabase>(),
      encryption: sl<CacheEncryptionService>(),
    ),
  );

  // Data — repositories delegate to AccountManager for the live active datasource.
  sl.registerLazySingleton<EmailRepository>(
    () => EmailRepositoryImpl(
      accountManager: sl<AccountManager>(),
      localDatasource: sl<EmailLocalDatasource>(),
    ),
  );
  sl.registerLazySingleton<CalendarRepository>(
    () => CalendarRepositoryImpl(accountManager: sl<AccountManager>()),
  );
  sl.registerLazySingleton<TasksRepository>(
    () => TasksRepositoryImpl(accountManager: sl<AccountManager>()),
  );

  // Domain — use cases
  sl.registerLazySingleton(() => GetEmails(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetEmail(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetMailFolders(sl<EmailRepository>()));
  sl.registerLazySingleton(() => MarkEmailAsRead(sl<EmailRepository>()));
  sl.registerLazySingleton(() => SendEmail(sl<EmailRepository>()));
  sl.registerLazySingleton(() => MoveEmail(sl<EmailRepository>()));
  sl.registerLazySingleton(() => DeleteEmail(sl<EmailRepository>()));
  sl.registerLazySingleton(() => EmptyFolder(sl<EmailRepository>()));
  sl.registerLazySingleton(() => DownloadAttachment(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetCachedEmails(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetCalendarEvents(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => CreateCalendarEvent(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => UpdateCalendarEvent(sl<CalendarRepository>()));
  sl.registerLazySingleton(() => GetTaskLists(sl<TasksRepository>()));
  sl.registerLazySingleton(() => GetTasks(sl<TasksRepository>()));
  sl.registerLazySingleton(() => CreateTask(sl<TasksRepository>()));
  sl.registerLazySingleton(() => UpdateTaskStatus(sl<TasksRepository>()));

  // Settings
  sl.registerLazySingleton(() => AppSettings());
  sl.registerLazySingleton(() => BadgeService());

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
    ),
  );

  // Presentation — BLoC factories
  sl.registerFactory(
    () => FolderListBloc(getMailFolders: sl<GetMailFolders>()),
  );
  sl.registerFactory(() => EmailListBloc(
        getEmails: sl<GetEmails>(),
        getCachedEmails: sl<GetCachedEmails>(),
        markEmailAsRead: sl<MarkEmailAsRead>(),
        moveEmail: sl<MoveEmail>(),
        deleteEmail: sl<DeleteEmail>(),
        emptyFolder: sl<EmptyFolder>(),
        accountManager: sl<AccountManager>(),
      ));
  sl.registerFactory(() => EmailDetailBloc(getEmail: sl<GetEmail>()));
  sl.registerFactory(
    () => CalendarBloc(getCalendarEvents: sl<GetCalendarEvents>()),
  );
  sl.registerFactory(() => ComposeBloc(sendEmail: sl<SendEmail>()));
  sl.registerFactory(() => TasksBloc(
        getTaskLists: sl<GetTaskLists>(),
        getTasks: sl<GetTasks>(),
        createTask: sl<CreateTask>(),
        updateTaskStatus: sl<UpdateTaskStatus>(),
      ));
  sl.registerFactory(() => EventEditBloc(
        createCalendarEvent: sl<CreateCalendarEvent>(),
        updateCalendarEvent: sl<UpdateCalendarEvent>(),
      ));
}
