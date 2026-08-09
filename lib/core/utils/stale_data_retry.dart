/// How long to wait between re-attempts of a first fetch that failed while
/// cached data was already on screen.
///
/// Both `FolderListBloc` and `EmailListBloc` load in two phases — cache, then
/// network — and both deliberately swallow a phase-two failure when the cache
/// had something to show: a stale folder count or message list is more use
/// than an error page. The cost is that the stale data then reads as
/// authoritative, and neither bloc is asked to load again until the user
/// refreshes by hand.
///
/// That is a real cold-start hazard rather than a theoretical one, because the
/// first fetch of the session is the one most likely to fail transiently: the
/// OAuth access token has usually expired overnight and is refreshed lazily by
/// the request itself (`AuthInterceptor._getValidToken`), a refresh that fails
/// on a transport error is deliberately not reported (it must not read as
/// revoked credentials), and `ConnectivityServiceImpl.isOnline` reports offline
/// on a *fast* socket failure — which is what a machine that has only just
/// finished bringing up its network or VPN produces. Retrying a few times
/// covers all of them without any of the code above having to become chattier.
const staleDataRetryDelays = [
  Duration(seconds: 2),
  Duration(seconds: 6),
  Duration(seconds: 15),
];
