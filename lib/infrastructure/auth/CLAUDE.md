# Auth Infrastructure (OAuth)

Gmail's Chrome-based loopback sign-in on macOS, and the `state` check both OAuth flows share. See [../../../CLAUDE.md](../../../CLAUDE.md) for architecture-wide rules.

## Gmail Sign-In Opens Chrome, Not Safari

On macOS, Gmail's OAuth flow **bypasses `flutter_web_auth_2`** and runs its own
loopback server (`LoopbackAuthFlow`, `infrastructure/auth/`), handing the
authorization URL to Chrome through a native channel
(`au.com.sharpblue.nightmail/browser_launcher`).

The plugin cannot be asked to do this. Its macOS implementation is the method
channel alone — `ASWebAuthenticationSession`, which always renders in Safari's
WebKit; `useWebview: false` is inert there because its Dart loopback server is
registered for Windows and Linux only. And that server calls `launchUrl`, i.e.
the *default* browser, so it could not be pointed at Chrome either. The point is
to land in the browser the user is already signed into Google with.

Four things here are load-bearing:

- **The redirect URI and the branch in `signIn()` must agree.** macOS is now in
  `_useLoopbackRedirect` (so Google is told `http://127.0.0.1:34572`) *and* in
  `_useOwnLoopback` (so the code waits on that port). Flipping only the first
  points Google at a socket nothing is listening on, and sign-in hangs silently
  until it times out rather than failing.
- **`NSWorkspace`, never `open -a "Google Chrome"`.** Release builds are
  sandboxed and the sandbox denies spawning a process while permitting
  LaunchServices, so the shell route works in debug and ships broken.
  `openInChrome` returns `false` rather than erroring when Chrome is absent, and
  `AuthBrowserLauncher` falls back to `launchUrl`.
- **`com.apple.security.network.server` in `Release.entitlements`** — the
  sandbox refuses the `HttpServer.bind` without it. Debug/profile are
  unsandboxed, so a passing `flutter run` proves nothing about this.
- **The port is closed in a `finally` and the app re-activated by hand.** An
  abandoned sign-in that left 34572 bound would fail every later attempt on
  "address already in use", and nothing brings the window back from Chrome
  otherwise — the plugin path got that from `WindowToFront`.

Which request on that port is the redirect is decided twice over. A request
carrying neither `code` nor `error` is answered 404 and ignored: the browser
asks for `/favicon.ico` off the back of the landing page, and completing on the
first request regardless resolves the flow with a URL carrying no authorization
code. A request carrying a `code` must also echo the `state` this flow minted,
or it is answered 400 and the sign-in fails — see below.

**Microsoft, Windows, Linux and Android are untouched.** Azure accepts the
`nightmail://` custom scheme for public clients, so macOS Microsoft sign-in still
goes through `ASWebAuthenticationSession`; Windows and Linux still use the
plugin's own loopback server and the default browser.

## Both OAuth Flows Send a `state`, and Refuse a Redirect Without It

`state` (RFC 6749 §10.12) is minted per sign-in in `signIn()`, carried in the
authorization URL and checked on the way back — `oauth_state.dart` holds both
halves, and both `GmailAuthService` and `MicrosoftAuthService` use it.

PKCE already stops a code somebody else injected from being *exchanged*: the
exchange carries this client's verifier and an injected code was issued against
a different challenge. What `state` adds is the step before that — a redirect
that did not come from the authorization URL this client opened is refused
rather than acted on, and in the loopback flow it is what decides which request
on the port *is* the redirect. Before it, anything that could reach
127.0.0.1:34572 during the window could resolve the flow with its own code.

Four things here are load-bearing:

- **A missing `state` is a failure, not a skipped check.** That is the whole of
  the bypass, and it is also what keeps the request side honest: leave `state`
  out of an authorization URL and the provider echoes nothing back, so the very
  first sign-in fails loudly rather than quietly losing the defence.
- **`LoopbackAuthFlow.authenticate` takes `expectedState` as a required named
  parameter.** A nullable one reinstates "absent means skip the check" at the
  call site.
- **A mismatch fails immediately rather than waiting for the real redirect.**
  Ignoring the request and carrying on would turn any genuine mismatch — a bug
  in this file, a provider quirk — into a five-minute silent hang, which is the
  failure mode this whole section otherwise exists to avoid. The attack traded
  away is somebody who can already reach the port cancelling a sign-in, which
  gains them nothing.
- **An `error` response is let through unchecked.** `state` protects the code;
  an error carries nothing to spend, and requiring one there would turn a
  legible `access_denied` into a mismatch message.

`signIn()` checks it on *every* path, not just the loopback one: neither
`flutter_web_auth_2`'s own loopback server (Windows/Linux), nor the
`nightmail://` intercept, nor the web popup does it for us — the plugin's
server resolves on the first request carrying a code, exactly as ours used to.
The value is a local in `signIn()` rather than a field: nothing serialises
sign-ins, and a redirect may only ever be checked against the state the flow it
belongs to sent. It is never derived from the PKCE verifier, which is the secret
half of PKCE and would end up in the URL and the browser's history.

On web the redirect lands on `callback.html`, which posts `window.location.href`
verbatim over the `BroadcastChannel`, so `state` arrives with the code — both
providers answer with a query (`response_mode: query` is explicit for Microsoft,
and the default for Google's `response_type=code`), and nothing in that path
rewrites the URL.

## Gmail Never Worked on iOS or Android — the OAuth Client Type Was Wrong

Confirmed by loading the authorization URL directly and reading Google's
decoded error: the app's one Google OAuth client is **Desktop application**
type, and Google removed custom-scheme redirect support from Desktop-type
clients in 2022 (`Error 400: invalid_request`, citing the "secure response
handling" policy, echoing back the exact `redirect_uri` sent). This was never
platform-specific breakage — mobile Gmail sign-in had no working path before
this was diagnosed, since `_effectiveRedirectUri` falls through to the raw
`redirectUri` (`nightmail://google-auth-callback`) on every platform except
the loopback ones (macOS, Windows, Linux — see above).

The fix needed two more OAuth clients in the same GCP project, not just
different builds of the same client:

- **iOS-type client** (Bundle ID `au.com.sharpblue.nightmail`) — but a bare
  scheme is *still* rejected even under this client type. Google requires a
  custom-scheme redirect to be reverse-DNS shaped: a period in the scheme, and
  a single-slash path (`scheme:/path`, not `scheme://path`). The iOS console
  form has no redirect-URI field to fill in either way; Google validates the
  shape, not a registered list.
- **Android-type client** (package name + SHA-1 fingerprint, one client per
  keystore since Console takes a single fingerprint each) — Google also
  disables custom URI scheme redirects **by default** for newly-created
  Android clients; it has to be turned back on under the client's Advanced
  settings. That alone was not enough, though: verified directly against the
  real client that Android enforces the *same* reverse-DNS shape requirement
  as iOS — the bare `nightmail://google-auth-callback` still got
  `invalid_request` with the custom-URI-scheme setting on, and only
  `au.com.sharpblue.nightmail:/google-auth-callback` was accepted. So
  `AppConfig.gmailRedirectUri` (`lib/core/config/app_config.dart`) uses the
  dotted scheme for iOS *and* Android — only the loopback desktop platforms
  keep the original `nightmail://google-auth-callback` (and they ignore this
  value entirely; see `_effectiveRedirectUri` above). Android's app-side
  wiring (`flutter_web_auth_2.CallbackActivity` in `AndroidManifest.xml`) now
  registers both schemes — `nightmail` is still Microsoft's, unaffected by any
  of this.

Neither client type is issued a client secret, and no other client type can
stand in for one on mobile either: a Desktop/Web-type client's secret is
useless here because the *redirect* is the actual blocker — Google dropped
custom-scheme redirect support for Desktop clients in 2022, so any client
that carries a secret is the wrong client type for the `au.com.sharpblue.
nightmail:/google-auth-callback` redirect regardless of what's typed into the
dialog (confirmed by reproducing `Error 400: redirect_uri_mismatch` with a
working desktop Client ID/Secret entered as a custom registration on iOS). A
custom app registration on mobile must be its own genuine iOS/Android-type
client, which Google never issues a secret for either. `showClientIdDialog`'s
Gmail call sites (`add_account_page.dart`, `account_selection_page.dart`)
set `requireSecret: !isMobile` for this reason — the field is hidden
entirely on mobile, not just optional — and the downstream
`GmailAuthService` call sends `credentials.clientSecret ?? ''` rather than
force-unwrapping.

