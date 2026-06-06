import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/exceptions.dart';
import '../../../infrastructure/auth/auth_service.dart';
import '../../../infrastructure/auth/auth_token.dart';
import 'auth_event.dart';
import 'auth_state.dart';

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc({required AuthService authService})
      : _authService = authService,
        super(const AuthInitial()) {
    on<AuthCheckRequested>(_onCheckRequested);
    on<AuthSignInRequested>(_onSignInRequested);
    on<AuthSignOutRequested>(_onSignOutRequested);
  }

  final AuthService _authService;

  Future<void> _onCheckRequested(
    AuthCheckRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading());
    try {
      final token = await _authService.getStoredToken();
      if (token == null) {
        emit(const AuthUnauthenticated());
        return;
      }
      if (token.isExpired && token.refreshToken == null) {
        await _authService.signOut();
        emit(const AuthUnauthenticated());
        return;
      }
      final valid = token.isAboutToExpire && token.refreshToken != null
          ? await _authService.refreshToken(token)
          : token;
      emit(AuthAuthenticated(userEmail: _extractEmail(valid)));
    } on AuthException catch (e) {
      await _authService.signOut();
      emit(AuthError(message: e.message));
    } catch (_) {
      emit(const AuthUnauthenticated());
    }
  }

  Future<void> _onSignInRequested(
    AuthSignInRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading());
    try {
      final token = await _authService.signIn();
      emit(AuthAuthenticated(userEmail: _extractEmail(token)));
    } on AuthException catch (e) {
      emit(AuthError(message: e.message));
    } catch (e) {
      emit(AuthError(message: e.toString()));
    }
  }

  Future<void> _onSignOutRequested(
    AuthSignOutRequested event,
    Emitter<AuthState> emit,
  ) async {
    await _authService.signOut();
    emit(const AuthUnauthenticated());
  }

  /// Pulls the email claim from the token scope string if present,
  /// otherwise falls back to a generic label.
  String _extractEmail(AuthToken token) {
    // The actual user email comes from the id_token or /me endpoint.
    // For now we surface whatever scope info is available.
    return token.scope?.contains('@') == true ? token.scope! : 'your account';
  }
}
