import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get_it/get_it.dart';

import 'core/config/oauth_client_id_storage.dart';
import 'core/settings/app_settings.dart';
import 'data/database/app_database.dart';
import 'data/datasources/local/delta_token_datasource.dart';
import 'data/datasources/local/email_local_datasource.dart';
import 'data/datasources/local/email_local_datasource_impl.dart';
import 'data/datasources/local/folder_local_datasource.dart';
import 'data/datasources/local/reminder_schedule_local_datasource.dart';
import 'data/datasources/local/sender_local_datasource.dart';
import 'data/datasources/local/sender_local_datasource_impl.dart';
import 'data/repositories/calendar_repository_impl.dart';
import 'data/repositories/contact_details_repository_impl.dart';
import 'data/repositories/directory_contacts_repository_impl.dart';
import 'data/repositories/email_repository_impl.dart';
import 'data/repositories/sender_repository_impl.dart';
import 'data/repositories/spam_filter_repository_impl.dart';
import 'data/repositories/system_contacts_repository_impl.dart';
import 'data/repositories/tasks_repository_impl.dart';
import 'data/services/eml_parser.dart';
// AI subsystem
import 'data/datasources/ai/ai_adapter_factory.dart';
import 'data/datasources/ai/ai_catalog_cache_datasource.dart';
import 'data/datasources/ai/ai_config_datasource.dart';
import 'data/datasources/ai/ai_provider_registry.dart';
import 'data/datasources/ai/models_dev_catalog_datasource.dart';
import 'data/datasources/ai/provider_models_datasource.dart';
import 'data/datasources/ai/inference/anthropic_adapter.dart';
import 'data/datasources/ai/inference/google_adapter.dart';
import 'data/datasources/ai/inference/openai_compatible_adapter.dart';
import 'data/repositories/ai/ai_catalog_repository_impl.dart';
import 'data/repositories/ai/ai_inference_repository_impl.dart';
import 'data/repositories/ai/ai_settings_repository_impl.dart';
import 'domain/repositories/ai/ai_catalog_repository.dart';
import 'domain/repositories/ai/ai_inference_repository.dart';
import 'domain/repositories/ai/ai_settings_repository.dart';
import 'domain/usecases/ai/compose_reply.dart';
import 'domain/usecases/ai/run_folder_agent.dart';
import 'presentation/blocs/ai/ai_compose_cubit.dart';
import 'presentation/blocs/ai/ai_folder_cubit.dart';
import 'presentation/blocs/ai/ai_settings_cubit.dart';
import 'domain/repositories/calendar_repository.dart';
import 'domain/repositories/contact_details_repository.dart';
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
import 'domain/usecases/rename_folder.dart';
import 'domain/usecases/empty_folder.dart';
import 'domain/usecases/get_calendar_events.dart';
import 'domain/usecases/get_contact_details.dart';
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
import 'domain/usecases/propose_new_time_from_email.dart';
import 'domain/usecases/cancel_meeting_from_email.dart';
import 'domain/usecases/remove_cancelled_meeting.dart';
import 'domain/usecases/respond_to_meeting_invite.dart';
import 'domain/usecases/update_calendar_event.dart';
import 'domain/usecases/update_task_due_date.dart';
import 'domain/usecases/update_task_status.dart';
import 'domain/usecases/get_cached_emails.dart';
import 'domain/usecases/clear_email_cache_for_folder.dart';
import 'domain/usecases/get_cached_folders.dart';
import 'infrastructure/accounts/account_manager.dart';
import 'infrastructure/accounts/account_storage.dart';
import 'infrastructure/badge/badge_service.dart';
import 'infrastructure/cache/cache_encryption_service.dart';
import 'infrastructure/notifications/calendar_reminder_service.dart';
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
      // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: accessible after first
      // unlock since reboot (including background execution contexts). Prevents
      // errSecInteractionNotAllowed (-25308) when the app cold-starts via a
      // notification tap and briefly runs in a background execution context
      // before reaching foreground. kSecAttrAccessibleWhenUnlocked (the default)
      // is not accessible during that brief background window.
      iOptions: const IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
      // Debug/profile builds are non-sandboxed and have no provisioning profile,
      // so kSecUseDataProtectionKeychain would fail with -34018. Release builds
      // have the sandbox + keychain-access-groups entitlement so can use it.
      mOptions: MacOsOptions(usesDataProtectionKeychain: kReleaseMode),
    ),
  );

  // iOS: one-time bulk migration from kSecAttrAccessibleWhenUnlocked to
  // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly. Items written before this
  // update use the old class and won't be found by reads that specify the new
  // class. This migrates all items in one shot on the first normal launch;
  // notification-tap launches where migration fails (-25308) are handled by
  // AccountCubit's auto-retry combined with lazy migration in AccountStorage.
  if (!kIsWeb && Platform.isIOS) {
    await _migrateIosKeychainAccessibility(sl<FlutterSecureStorage>());
  }

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
  sl.registerLazySingleton<ReminderScheduleLocalDatasource>(() => sl<AppDatabase>());
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
  sl.registerLazySingleton<ContactDetailsRepository>(
    () => ContactDetailsRepositoryImpl(accountManager: sl<AccountManager>()),
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
  sl.registerLazySingleton(() => RenameFolder(sl<EmailRepository>()));
  sl.registerLazySingleton(() => DownloadAttachment(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetCachedEmails(sl<EmailRepository>()));
  sl.registerLazySingleton(() => ClearEmailCacheForFolder(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetCachedFolders(sl<EmailRepository>()));
  sl.registerLazySingleton(() => RecordKnownSenders(sl<SenderRepository>()));
  sl.registerLazySingleton(() => CheckSenderAnomaly(sl<SenderRepository>()));
  sl.registerLazySingleton(() => MergeSenderAddresses(sl<SenderRepository>()));
  sl.registerLazySingleton(() => SearchContacts(
        senderRepository: sl<SenderRepository>(),
        systemContactsRepository: sl<SystemContactsRepository>(),
        directoryContactsRepository: sl<DirectoryContactsRepository>(),
      ));
  sl.registerLazySingleton(() => GetContactDetails(sl<ContactDetailsRepository>()));
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
  sl.registerLazySingleton(() => ProposeNewTimeFromEmail(sl<CalendarRepository>()));
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
  sl.registerLazySingleton(
    () => CalendarReminderService(
      accountManager: sl<AccountManager>(),
      notificationService: sl<NotificationService>(),
      database: sl<ReminderScheduleLocalDatasource>(),
    ),
  );

  // Presentation — singletons
  sl.registerLazySingleton(() => ThemeCubit());
  sl.registerLazySingleton(
    () => AccountCubit(
      accountManager: sl<AccountManager>(),
      emailRepository: sl<EmailRepository>(),
      calendarReminderService: sl<CalendarReminderService>(),
    ),
  );
  sl.registerLazySingleton(
    () => MailPollerCubit(
      accountManager: sl<AccountManager>(),
      appSettings: sl<AppSettings>(),
      badgeService: sl<BadgeService>(),
      database: sl<DeltaTokenDatasource>(),
      getCachedFolders: sl<GetCachedFolders>(),
      notificationService: sl<NotificationService>(),
    ),
  );

  // Presentation — BLoC factories
  sl.registerFactory(
    () => FolderListBloc(
      getMailFolders: sl<GetMailFolders>(),
      getCachedFolders: sl<GetCachedFolders>(),
      createFolder: sl<CreateFolder>(),
      renameFolder: sl<RenameFolder>(),
      accountManager: sl<AccountManager>(),
    ),
  );
  sl.registerFactory(() => EmailListBloc(
        getEmails: sl<GetEmails>(),
        getCachedEmails: sl<GetCachedEmails>(),
        clearEmailCacheForFolder: sl<ClearEmailCacheForFolder>(),
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
          notificationService: sl<NotificationService>(),
          accountManager: sl<AccountManager>(),
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

  // ---------------------------------------------------------------------------
  // AI subsystem
  // ---------------------------------------------------------------------------
  // Dedicated Dio for the AI subsystem (models.dev catalog fetch + provider
  // adapters). The app intentionally has no shared Dio singleton — each HTTP
  // concern builds its own client — so one instance is registered here and
  // reused by every AI consumer rather than constructing a fresh client per
  // adapter.
  //
  // Explicit timeouts (M2): default Dio leaves every timeout null, so the cold
  // first-launch catalog fetch (~2.4MB from models.dev) and live `/models`
  // lookups could hang forever on a slow/captive-portal network, leaving AI
  // Settings stuck on a spinner with no error. These bounds make hangs surface
  // as DioException → NetworkException/ProviderUnreachable. Streaming inference
  // overrides receiveTimeout per-call (Options) so long token streams aren't
  // cut by the 60s default.
  sl.registerLazySingleton<Dio>(
    () => Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ),
    ),
  );

  // Datasources
  sl.registerLazySingleton<ModelsDevCatalogDatasource>(
    () => ModelsDevCatalogDatasourceImpl(dio: sl<Dio>()),
  );
  sl.registerLazySingleton<AiCatalogCacheDatasource>(
    () => AiCatalogCacheDatasourceImpl(database: sl<AppDatabase>()),
  );
  sl.registerLazySingleton<AiConfigDatasource>(
    () => AiConfigDatasourceImpl(database: sl<AppDatabase>()),
  );
  sl.registerLazySingleton<ProviderModelsDatasource>(
    () => ProviderModelsDatasourceImpl(dio: sl<Dio>()),
  );

  // Registry — single source of truth for available providers/models.
  sl.registerLazySingleton<AiProviderRegistry>(
    () => AiProviderRegistry(
      catalogDatasource: sl<ModelsDevCatalogDatasource>(),
      cacheDatasource: sl<AiCatalogCacheDatasource>(),
      configDatasource: sl<AiConfigDatasource>(),
    ),
  );

  // Wire adapters + factory (lazy resolution by AiWireProtocol).
  sl.registerLazySingleton<AiAdapterFactory>(
    () => AiAdapterFactory(
      openAiAdapter: OpenAiCompatibleAdapter(dio: sl<Dio>()),
      anthropicAdapter: AnthropicAdapter(dio: sl<Dio>()),
      // Azure OpenAI / AI Foundry: OpenAI shape with the `api-key` header.
      azureAdapter:
          OpenAiCompatibleAdapter(dio: sl<Dio>(), useApiKeyHeader: true),
      // Google Gemini: native `generateContent` API.
      googleAdapter: GoogleAdapter(dio: sl<Dio>()),
    ),
  );

  // Repositories
  sl.registerLazySingleton<AiCatalogRepository>(
    () => AiCatalogRepositoryImpl(
      registry: sl<AiProviderRegistry>(),
      providerModels: sl<ProviderModelsDatasource>(),
    ),
  );
  sl.registerLazySingleton<AiSettingsRepository>(
    () => AiSettingsRepositoryImpl(
      configDatasource: sl<AiConfigDatasource>(),
      secureStorage: sl<FlutterSecureStorage>(),
    ),
  );
  sl.registerLazySingleton<AiInferenceRepository>(
    () => AiInferenceRepositoryImpl(
      registry: sl<AiProviderRegistry>(),
      adapterFactory: sl<AiAdapterFactory>(),
      settingsRepository: sl<AiSettingsRepository>(),
    ),
  );

  // Use cases
  sl.registerLazySingleton(
    () => ComposeReply(
      settingsRepository: sl<AiSettingsRepository>(),
      inferenceRepository: sl<AiInferenceRepository>(),
      // Privacy "cloud bodies" guard (H1): ComposeReply resolves the routed
      // provider's kind via the catalog registry to decide whether the quoted
      // original body may be sent to a cloud provider.
      catalogRepository: sl<AiCatalogRepository>(),
    ),
  );

  // Folder agent loop (§3): builds its four read-only AgentTools internally,
  // so they are not registered separately.
  sl.registerLazySingleton(
    () => RunFolderAgent(
      settingsRepository: sl<AiSettingsRepository>(),
      inferenceRepository: sl<AiInferenceRepository>(),
      catalogRepository: sl<AiCatalogRepository>(),
      getEmails: sl<GetEmails>(),
      getEmail: sl<GetEmail>(),
      searchEmails: sl<SearchEmails>(),
      getMailFolders: sl<GetMailFolders>(),
    ),
  );

  // Presentation — AI cubits (factories)
  sl.registerFactory(() => AiComposeCubit(composeReply: sl<ComposeReply>()));
  sl.registerFactory(
    () => AiFolderCubit(runFolderAgent: sl<RunFolderAgent>()),
  );
  sl.registerFactory(
    () => AiSettingsCubit(
      catalogRepository: sl<AiCatalogRepository>(),
      settingsRepository: sl<AiSettingsRepository>(),
    ),
  );
}

// Sentinel key written with the new accessibility once migration is complete.
// On subsequent launches this is readable in background (AfterFirstUnlock) so
// the migration check is always fast.
const _kMigrationSentinel = 'nightmail_keychain_migration_v1';

// Migration storage: no accessibility filter in reads, so SecItemCopyMatching
// returns items regardless of their kSecAttrAccessible attribute.
const _kMigrationStorage = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: null),
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

// Migrates all iOS keychain items from kSecAttrAccessibleWhenUnlocked (the
// plugin's default) to kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
//
// Strategy: readAll() from a no-accessibility-filter storage finds items of any
// class; delete() + write() (the plugin's delete nils the accessibility before
// querying, so it removes any class variant) re-stores each item with the new
// class. A sentinel key (written with the new class) guards against re-running.
//
// If readAll() throws -25308 (device locked / protected data unavailable, which
// can happen during a notification-tap background launch), migration is skipped
// without writing the sentinel so it retries on the next launch. The startup
// path handles this via AccountCubit auto-retry + AccountStorage lazy migration.
Future<void> _migrateIosKeychainAccessibility(
  FlutterSecureStorage newStorage,
) async {
  try {
    if (await newStorage.read(key: _kMigrationSentinel) != null) return;

    final Map<String, String> all;
    try {
      all = await _kMigrationStorage.readAll();
    } on PlatformException catch (e) {
      if (e.details == -25308) return; // Protected data unavailable — retry next launch
      return;
    }

    for (final entry in all.entries) {
      if (entry.key == _kMigrationSentinel) continue;
      try {
        await newStorage.delete(key: entry.key);
        await newStorage.write(key: entry.key, value: entry.value);
      } catch (_) {}
    }

    await newStorage.write(key: _kMigrationSentinel, value: '1');
  } catch (_) {}
}
