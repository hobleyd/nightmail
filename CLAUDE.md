# NightMail — Claude Code Guide

## Architecture

Clean Architecture, 4 layers. Never bypass layers.

```
core/       — Failure, UseCase, Exception types
domain/     — Entities, Repository interfaces, Use cases
data/       — Models, Datasources, Repository impls
presentation/ — BLoCs/Cubits, Pages, Widgets
```

- DI via `get_it` (`sl<T>()` in `injection_container.dart`)
- Error handling: `fpdart` `Either<Failure, T>` (not `dartz`)
- State: `flutter_bloc`
- Bundle IDs: always `au.com.sharpblue` prefix (never `com.sharpblue`)
- An `AuthException` from a token refresh means "replace these credentials": it
  flags the account for re-auth and makes `AuthBloc` discard the token. Offline
  is a `NetworkException` — see `infrastructure/auth/token_refresh_error.dart`

## Building

```bash
flutter pub get
flutter build macos --debug
flutter run
```

Always `flutter clean` after changing entitlements or code signing settings.

## Subsystem Notes

The rest of this repo's accumulated "why" lives in `CLAUDE.md`/`.md` files next
to the code they describe, not here — each one only needs to be read while
you're actually working in that area. **Read the relevant file before touching
that subsystem**; it holds the incident history and constraints a generic pass
would re-break.

### Native / Desktop

- [`macos/CLAUDE.md`](macos/CLAUDE.md) — native platform channels, TCC
  (Contacts) permissions, code-signing for permission dialogs
- [`lib/core/platform/CLAUDE.md`](lib/core/platform/CLAUDE.md) —
  `desktop_multi_window` sub-windows, the FFI-plugin isolate hazard, window
  bounds persistence

### Auth

- [`lib/infrastructure/auth/CLAUDE.md`](lib/infrastructure/auth/CLAUDE.md) —
  Gmail's Chrome-based loopback sign-in on macOS, the OAuth `state` check both
  providers share

### Mail Data & Rendering

- [`lib/data/database/CLAUDE.md`](lib/data/database/CLAUDE.md) — why the
  sqlite cache database is never explicitly closed
- [`docs/claude/message-parsing.md`](docs/claude/message-parsing.md) —
  parsing fetched messages off the UI isolate, multipart body assembly
- [`docs/claude/attachments-and-previews.md`](docs/claude/attachments-and-previews.md)
  — previewing an attached `.eml`/Outlook `itemAttachment`/Markdown file in
  place
- [`docs/claude/webviews.md`](docs/claude/webviews.md) — reading-pane and
  compose-editor webviews: CSP, remote-image blocking, linkification, focus
  handling, HTML sanitisation
- [`docs/claude/body-links.md`](docs/claude/body-links.md) — `mailto:` and
  cloud-document link handling in a message body
- [`docs/claude/imap.md`](docs/claude/imap.md) — serialising IMAP commands
  through one connection/mailbox selection

### Mail List & Folders

- [`lib/presentation/blocs/email_list/CLAUDE.md`](lib/presentation/blocs/email_list/CLAUDE.md)
  — thread grouping across folders, which message heads a thread, folder
  labels on list rows, the account-switch race
- [`lib/presentation/blocs/folder_list/CLAUDE.md`](lib/presentation/blocs/folder_list/CLAUDE.md)
  — optimistic unread counts, cache-freeze recovery, folder
  create/move/delete/empty
- [`lib/presentation/blocs/mail_poller/CLAUDE.md`](lib/presentation/blocs/mail_poller/CLAUDE.md)
  — which folders a poll cycle syncs, delta-cursor rules

### Calendar & Reminders

- [`lib/infrastructure/calendar/CLAUDE.md`](lib/infrastructure/calendar/CLAUDE.md)
  — meeting-invite banners, forwarding, Gmail RSVPs, the offline calendar
  cache, room booking, Google's organizer/guest-notification quirks
- [`lib/infrastructure/notifications/CLAUDE.md`](lib/infrastructure/notifications/CLAUDE.md)
  — the overdue-tasks badge, the OS notification-scheduling budget

### Features

- [`docs/claude/out-of-office.md`](docs/claude/out-of-office.md) — Settings
  > Out of Office, across Microsoft Graph and Gmail
- [`docs/claude/ai-subsystem.md`](docs/claude/ai-subsystem.md) — deliberate
  Clean-Architecture deviations in the AI compose/inference slice
- [`lib/infrastructure/update/CLAUDE.md`](lib/infrastructure/update/CLAUDE.md)
  — in-app update mechanism (macOS/Windows/Android)
- [`lib/infrastructure/contacts/CLAUDE.md`](lib/infrastructure/contacts/CLAUDE.md)
  — local-only recipient typeahead, daily contact sync
