import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get_it/get_it.dart';

import 'data/datasources/remote/graph_api_remote_datasource.dart';
import 'data/datasources/remote/graph_api_remote_datasource_impl.dart';
import 'data/repositories/email_repository_impl.dart';
import 'domain/repositories/email_repository.dart';
import 'domain/usecases/get_email.dart';
import 'domain/usecases/get_emails.dart';
import 'domain/usecases/get_mail_folders.dart';
import 'domain/usecases/mark_email_as_read.dart';
import 'infrastructure/auth/auth_service.dart';
import 'infrastructure/auth/microsoft_auth_service.dart';
import 'infrastructure/auth/token_storage.dart';
import 'infrastructure/http/graph_http_client.dart';
import 'presentation/blocs/auth/auth_bloc.dart';
import 'presentation/blocs/email_detail/email_detail_bloc.dart';
import 'presentation/blocs/email_list/email_list_bloc.dart';
import 'presentation/blocs/folder_list/folder_list_bloc.dart';
import 'presentation/blocs/theme/theme_cubit.dart';

final sl = GetIt.instance;

Future<void> configureDependencies({
  required String clientId,
  required String tenantId,
  required String redirectUri,
}) async {
  // Infrastructure — storage & auth
  sl.registerLazySingleton<FlutterSecureStorage>(
    () => const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    ),
  );

  sl.registerLazySingleton<TokenStorage>(
    () => TokenStorage(sl<FlutterSecureStorage>()),
  );

  sl.registerLazySingleton<AuthService>(
    () => MicrosoftAuthService(
      clientId: clientId,
      tenantId: tenantId,
      redirectUri: redirectUri,
      tokenStorage: sl<TokenStorage>(),
      httpClient: Dio(),
    ),
  );

  // Infrastructure — HTTP
  sl.registerLazySingleton<GraphHttpClient>(
    () => GraphHttpClient(authService: sl<AuthService>()),
  );

  // Data — datasources
  sl.registerLazySingleton<GraphApiRemoteDatasource>(
    () => GraphApiRemoteDatasourceImpl(client: sl<GraphHttpClient>()),
  );

  // Data — repositories
  sl.registerLazySingleton<EmailRepository>(
    () => EmailRepositoryImpl(remoteDatasource: sl<GraphApiRemoteDatasource>()),
  );

  // Domain — use cases
  sl.registerLazySingleton(() => GetEmails(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetEmail(sl<EmailRepository>()));
  sl.registerLazySingleton(() => GetMailFolders(sl<EmailRepository>()));
  sl.registerLazySingleton(() => MarkEmailAsRead(sl<EmailRepository>()));

  // Presentation — theme cubit (singleton — app-wide state)
  sl.registerLazySingleton(() => ThemeCubit());

  // Presentation — BLoCs (factories so each screen gets a fresh instance)
  sl.registerFactory(() => AuthBloc(authService: sl<AuthService>()));
  sl.registerFactory(() => FolderListBloc(getMailFolders: sl<GetMailFolders>()));
  sl.registerFactory(() => EmailListBloc(
        getEmails: sl<GetEmails>(),
        markEmailAsRead: sl<MarkEmailAsRead>(),
      ));
  sl.registerFactory(() => EmailDetailBloc(getEmail: sl<GetEmail>()));
}
