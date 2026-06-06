import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/infrastructure/auth/auth_service.dart';
import 'package:nightmail/infrastructure/auth/auth_token.dart';
import 'package:nightmail/presentation/blocs/auth/auth_bloc.dart';
import 'package:nightmail/presentation/blocs/auth/auth_event.dart';
import 'package:nightmail/presentation/blocs/auth/auth_state.dart';

import 'auth_bloc_test.mocks.dart';

@GenerateMocks([AuthService])
void main() {
  late AuthBloc bloc;
  late MockAuthService mockAuthService;

  final tToken = AuthToken(
    accessToken: 'access-token',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    refreshToken: 'refresh-token',
  );

  setUp(() {
    provideDummy<AuthToken>(tToken);
    mockAuthService = MockAuthService();
    bloc = AuthBloc(authService: mockAuthService);
  });

  tearDown(() => bloc.close());

  group('AuthCheckRequested', () {
    test('emits Authenticated when a valid token is stored', () async {
      when(mockAuthService.getStoredToken())
          .thenAnswer((_) async => tToken);

      bloc.add(const AuthCheckRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          isA<AuthLoading>(),
          isA<AuthAuthenticated>(),
        ]),
      );
    });

    test('emits Unauthenticated when no token is stored', () async {
      when(mockAuthService.getStoredToken()).thenAnswer((_) async => null);

      bloc.add(const AuthCheckRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          isA<AuthLoading>(),
          isA<AuthUnauthenticated>(),
        ]),
      );
    });

    test('emits Unauthenticated and clears token when expired with no refresh',
        () async {
      final expiredToken = AuthToken(
        accessToken: 'old',
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      when(mockAuthService.getStoredToken())
          .thenAnswer((_) async => expiredToken);
      when(mockAuthService.signOut()).thenAnswer((_) async {});

      bloc.add(const AuthCheckRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          isA<AuthLoading>(),
          isA<AuthUnauthenticated>(),
        ]),
      );
      verify(mockAuthService.signOut()).called(1);
    });
  });

  group('AuthSignInRequested', () {
    test('emits Authenticated on successful sign-in', () async {
      when(mockAuthService.signIn()).thenAnswer((_) async => tToken);

      bloc.add(const AuthSignInRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          isA<AuthLoading>(),
          isA<AuthAuthenticated>(),
        ]),
      );
    });

    test('emits AuthError when sign-in throws AuthException', () async {
      when(mockAuthService.signIn())
          .thenThrow(const AuthException(message: 'User cancelled'));

      bloc.add(const AuthSignInRequested());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          isA<AuthLoading>(),
          isA<AuthError>(),
        ]),
      );
    });
  });

  group('AuthSignOutRequested', () {
    test('emits Unauthenticated and clears storage', () async {
      when(mockAuthService.signOut()).thenAnswer((_) async {});

      bloc.add(const AuthSignOutRequested());

      await expectLater(
        bloc.stream,
        emits(isA<AuthUnauthenticated>()),
      );
      verify(mockAuthService.signOut()).called(1);
    });
  });
}
