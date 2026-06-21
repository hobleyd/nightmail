# NightMail

NightMail is an Enterprise (i.e. requires a CLIENT_ID from the tenant and in Googles weird case also a CLIENT_SECRET) desktop and mobile email client built with Flutter. It supports Microsoft 365, Google Workspace, Gmail, and any standard IMAP/SMTP account — all from a single unified interface.

The app provides a three-pane layout (folders, message list, reading pane) with integrated calendar, tasks, and contacts across all supported providers.

---

## Features

### Email
- Read, compose, reply, reply-all, and forward messages
- HTML and plain text rendering
- Attachment download and upload
- Move messages between folders
- Mark as read/unread
- Report junk/spam
- Full-text search within folders
- Sender anomaly and spam detection

### Folders
- Full folder hierarchy with unread counts
- Create folders via right-click context menu
- Empty folder (with permanent delete option)
- Incremental sync with delta tokens (Microsoft 365)

### Calendar
- View, create, update, and delete events
- Accept, tentatively accept, or decline meeting invitations
- Check attendee availability
- Propose new meeting times
- Recurring event support
- Timezone-aware scheduling
- Supported backends: Microsoft Graph, Google Calendar, Nextcloud CalDAV, macOS/iOS EventKit

### Tasks
- Create and manage tasks across Microsoft To Do and Google Tasks
- Set due dates, importance, and status
- Attach emails to tasks

### Contacts
- Typeahead in the compose window drawing from three sources:
  - Previously known senders (local database)
  - System contacts (macOS Contacts app)
  - Organisational directory (Microsoft People API / Google Directory)

### Accounts
- Multiple accounts from different providers simultaneously
- Per-account folder, calendar, and task views
- Secure token storage (system Keychain / encrypted preferences)

---

## Supported Providers

### Microsoft 365 / Office 365

NightMail connects to Microsoft 365 via the Microsoft Graph API using OAuth 2.0 with PKCE.

**What you need:**

1. An Azure AD app registration in your tenant (or a shared multi-tenant registration).
2. The following **API Permissions** granted (delegated):

   | Permission | Purpose |
   |---|---|
   | `User.Read` | Sign-in and profile |
   | `Mail.Read` | Read messages |
   | `Mail.ReadWrite` | Move, delete, flag messages |
   | `Mail.Send` | Send messages |
   | `MailboxSettings.Read` | Folder names and settings |
   | `Calendars.ReadWrite` | Read and write calendar events |
   | `Tasks.ReadWrite` | Read and write Microsoft To Do |
   | `People.Read` | Organisation contact suggestions |
   | `offline_access` | Refresh tokens (required) |

3. A **redirect URI** configured for the platform:
   - macOS / iOS: `nightmail://auth-callback` (Mobile and Desktop platform type)
   - Windows / Linux: `http://localhost:34571` (Mobile and Desktop platform type)

4. An admin in the tenant must grant **admin consent** for `People.Read` and the mail/calendar scopes if your organisation requires it.

**Your Azure Client ID** (and optionally a custom tenant ID) can be entered directly in NightMail under Settings → Accounts when adding a Microsoft 365 account.

**Personal Microsoft accounts** (outlook.com, hotmail.com, live.com) can connect using the common endpoint — no Azure tenant required, but you still need an app registration with the above scopes and redirect URI.

---

### Google Workspace / Gmail

NightMail connects to Google via the Gmail API, Google Calendar API, Google Tasks API, and Google People API using OAuth 2.0 with PKCE.

**What you need:**

1. A project in Google Cloud Console with the following APIs enabled:
   - Gmail API
   - Google Calendar API
   - Google Tasks API
   - Google People API

2. An **OAuth 2.0 Client ID** of type **Desktop application**.

3. The following OAuth scopes authorised:

   | Scope | Purpose |
   |---|---|
   | `gmail.modify` | Read, move, label, and send messages |
   | `calendar.readonly` | Read calendar events |
   | `tasks` | Read and write Google Tasks |
   | `contacts.readonly` | Personal contact suggestions |
   | `directory.readonly` | Organisation directory suggestions |

4. A **redirect URI** added to the OAuth client:
   - macOS / iOS: `nightmail://google-auth-callback`
   - Windows / Linux: `http://localhost` (loopback)

5. For Google Workspace organisations, a Workspace admin may need to mark the app as trusted under **Security → API Controls → App Access Control** if the scopes require verification or if the app is not published to the Google Workspace Marketplace.

**Note:** `directory.readonly` requires a Google Workspace account (it is not available for personal Gmail accounts). Organisation contact suggestions will simply not appear for personal Gmail users.

**Your Google Client ID** can be entered in NightMail under Settings → Accounts when adding a Google / Gmail account.

---

### IMAP / SMTP (Generic, including self-hosted)

NightMail supports any standard IMAP + SMTP email account. No app registration or cloud project is required.

**What you need:**

- IMAP server hostname, port, and SSL setting (default: port 993, SSL enabled)
- SMTP server hostname, port, and TLS setting (default: port 587, STARTTLS)
- Your email address and an **app-specific password**

For providers that disable basic password authentication (most hosted services), generate an app password:
- **Gmail (personal):** Google Account → Security → 2-Step Verification → App Passwords
- **Outlook.com / Hotmail:** Microsoft Account → Security → Advanced Security → App Passwords
- **iCloud Mail:** Apple ID → Sign-In & Security → App-Specific Passwords
- **Fastmail, ProtonMail Bridge, etc.:** follow each provider's documentation

**Optional: Nextcloud CalDAV**

IMAP accounts can optionally link a Nextcloud calendar via CalDAV. Provide your Nextcloud server URL and credentials when adding the account.

---

## Platform Support

| Platform | Email | Calendar | Tasks | System Contacts |
|---|---|---|---|---|
| macOS | ✓ | ✓ | ✓ | ✓ |
| iOS | ✓ | ✓ | ✓ | ✓ |
| Android | ✓ | ✓ | ✓ | ✓ |
| Windows | ✓ | ✓ | ✓ | — |
| Linux | ✓ | ✓ | ✓ | — |

---

## Building from Source

```bash
flutter pub get
flutter build macos --debug
```

Run `flutter clean` after any changes to entitlements or code-signing settings.

See `CLAUDE.md` for architecture conventions, macOS code-signing requirements, and platform channel gotchas.
