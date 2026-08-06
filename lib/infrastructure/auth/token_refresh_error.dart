import 'package:dio/dio.dart';

import '../../core/error/exceptions.dart';

/// Classifies a failed OAuth token **refresh** as either a transport failure
/// ([NetworkException]) or a credential failure ([AuthException]).
///
/// The distinction is load-bearing, not cosmetic. `AuthInterceptor` treats every
/// [AuthException] out of a refresh as proof that the stored credentials have
/// gone bad: it fires `onAuthFailure`, which flags the account in
/// `AccountCubit.unauthenticatedAccountIds` and draws the "sign in again"
/// banner. `AuthBloc` goes further and calls `signOut()`, discarding the stored
/// token. Neither is a sane response to a machine that is merely offline — the
/// refresh token was never spent, and the next attempt on a real network
/// succeeds.
///
/// A DNS failure is the common shape: it arrives as `connectionError`, whose
/// message reads "The connection errored: Failed host lookup:
/// 'oauth2.googleapis.com'". That is what used to reach the user as "Token
/// refresh failed" with an invitation to re-authenticate, most often on a laptop
/// resuming before its network is up.
///
/// Only the *refresh* path is classified this way. A failed token *exchange*
/// belongs to an interactive sign-in the user is watching: the message is shown
/// to them directly, no flag is latched and no token is discarded, so it stays
/// an [AuthException].
Exception tokenRefreshFailure(DioException e, String detail) {
  if (isTransportFailure(e)) {
    return NetworkException(
      message: 'Could not reach the sign-in service: $detail',
    );
  }
  return AuthException(message: 'Token refresh failed: $detail');
}

/// True when the request never got an answer from the token endpoint, so
/// nothing at all has been learnt about the credentials it carried.
///
/// Anything the endpoint *did* answer — `invalid_grant` on a revoked refresh
/// token, a 400 for a mismatched client, a 5xx — is left to
/// [tokenRefreshFailure]'s credential branch, since a response means the
/// credentials were seen and judged.
bool isTransportFailure(DioException e) => switch (e.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        true,
      _ => false,
    };
