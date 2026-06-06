import 'package:equatable/equatable.dart';

sealed class AuthState extends Equatable {
  const AuthState();

  @override
  List<Object?> get props => [];
}

/// Before the startup token check completes.
final class AuthInitial extends AuthState {
  const AuthInitial();
}

/// Token check or sign-in in progress.
final class AuthLoading extends AuthState {
  const AuthLoading();
}

/// Valid token exists; user is authenticated.
final class AuthAuthenticated extends AuthState {
  const AuthAuthenticated({required this.userEmail});
  final String userEmail;

  @override
  List<Object?> get props => [userEmail];
}

/// No valid token; sign-in screen should be shown.
final class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated();
}

/// Sign-in or refresh failed.
final class AuthError extends AuthState {
  const AuthError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
