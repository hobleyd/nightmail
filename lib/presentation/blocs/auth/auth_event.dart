import 'package:equatable/equatable.dart';

sealed class AuthEvent extends Equatable {
  const AuthEvent();

  @override
  List<Object?> get props => [];
}

/// Dispatched on app start to check for a stored/valid token.
final class AuthCheckRequested extends AuthEvent {
  const AuthCheckRequested();
}

/// User tapped "Sign in with Microsoft".
final class AuthSignInRequested extends AuthEvent {
  const AuthSignInRequested();
}

/// User signed out.
final class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested();
}
