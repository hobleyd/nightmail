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
- Spam filter synced across IMAP clients via a dedicated server-side folder
- Delete a conversation thread's in-folder messages from the reading pane
- Double-click an image in a message to open it in a resizable window
- Spell-checking with inline suggestions in the compose editor (macOS, Windows, Linux)
- Compose editor: font-family dropdown, custom font-colour palette, and pasting/resizing images inline
- Select and copy message text (subject, sender, recipients, date, body) with standard platform shortcuts (Cmd/Ctrl+C)

### Folders
- Full folder hierarchy with unread counts
- Create folders via right-click context menu
- Empty folder (with permanent delete option)
- Incremental sync with delta tokens (Microsoft 365)
- Drag folders in the list to reparent them

### Calendar
- View, create, update, and delete events
- Accept, tentatively accept, or decline meeting invitations
- Check attendee availability, with a side-by-side schedule pane for finding a
  free slot (see below)
- Propose new meeting times
- Recurring event support
- Timezone-aware scheduling
- Google Meet toggle for Gmail meetings
- Supported backends: Microsoft Graph, Google Calendar, Nextcloud CalDAV, macOS/iOS EventKit

**Meeting colours** are driven by your relationship to each meeting (your
participation), mapped to a single shared scheme so Gmail and Microsoft 365
events are coloured consistently — the same situation gets the same colour on
every account, regardless of the provider-specific fields underneath:

| Your participation | Colour |
|---|---|
| Organiser (your own meeting) | 🟢 Green |
| Accepted someone else's | 🔵 Blue |
| Tentative / not yet responded | 🟡 Yellow |
| Declined | ⚪ Grey |
| On your calendar (no response signal) | 🔵 Blue |
| Out-of-office (Microsoft 365 only) | 🔴 Red |
| Working elsewhere (Microsoft 365 only) | ⚪ Grey |

Out-of-office and working-elsewhere are free/busy states with no participation
equivalent, so they override the scheme; Gmail's event feed doesn't report
them, so they appear on Microsoft 365 only.

**Finding a free slot.** Add guests to a meeting and a **Find a time** link
appears under the Guests field, opening a schedule pane beside the form. It
shows 07:00–20:00 of the meeting's day with every participant's busy blocks
side by side; click a slot to move the meeting there. It's always available once
there's at least one guest — you don't have to hit a clash first — and each
guest also gets a one-line free/busy summary for the meeting's own time.

What the pane can show depends on the provider:

| Backend | Free/busy detail |
|---|---|
| Microsoft 365 | Busy / tentative / out-of-office / working elsewhere, with meeting titles where shared |
| Google Calendar | Busy intervals only — no titles, no tentative/OOF distinction (a `freeBusy` API limitation) |
| Nextcloud CalDAV | None; CalDAV free/busy needs the RFC 6638 scheduling extensions, which aren't universally supported |

Guests whose free/busy isn't visible are left out of the summary rather than
being reported as free — a blank row means "not known", not "available".

Google Calendar free/busy needs the `calendar.freebusy` OAuth scope. Gmail
accounts added before that scope was requested keep a token without it and show
no availability until they're signed in again.

### Tasks
- Create and manage tasks across Microsoft To Do and Google Tasks
- Set due dates, importance, and status
- Attach emails to tasks (or link the source email in notes for providers without an attachment API)
- Expandable task notes with a link back to the source email

### Contacts
- Typeahead in the compose window drawing from three sources:
  - Previously known senders (local database)
  - System contacts (macOS Contacts app)
  - Organisational directory (Microsoft People API / Google Directory)

### Accounts
- Multiple accounts from different providers simultaneously
- Per-account folder, calendar, and task views
- Secure token storage (system Keychain / encrypted preferences)
- Clear an account's local cache without removing the account

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
   | `calendar.events` | Read and write calendar events |
   | `calendar.calendarlist.readonly` | Resolve a calendar's default reminder minutes |
   | `calendar.freebusy` | Attendee free/busy for the scheduling pane |
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

**Linux:** the compose editor's spell-checking relies on WebKitGTK's system
spell-checker, which uses hunspell. Install hunspell and a dictionary for your
locale (e.g. `sudo apt install hunspell hunspell-en-au`), otherwise misspelled
words will not be underlined and no correction suggestions will appear.

See `CLAUDE.md` for architecture conventions, macOS code-signing requirements, and platform channel gotchas.
