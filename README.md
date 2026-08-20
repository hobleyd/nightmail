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
- URLs typed as plain text in a message become clickable links, with a hover preview and a copy-link button
- The sender's address is clickable to compose a reply, with a copy button on hover
- A thread's collapsed row shows the newest message from someone else, not just the newest overall
- The provider's own flag (Graph flag, Gmail star, IMAP `\Flagged`) shown as a read-only icon on the message list
- `mailto:` links open the compose window instead of the OS's default mail client
- The compose window reopens at the size and position it was last closed at

### Folders
- Full folder hierarchy with unread counts
- Create folders via right-click context menu
- Empty folder (with permanent delete option)
- Incremental sync with delta tokens (Microsoft 365)
- Incremental sync for Gmail (history API) and IMAP (UID-based) accounts too
- Drag folders in the list to reparent them
- Dragging an email near the top/bottom edge of the folder list auto-scrolls it, and dwelling over a collapsed folder auto-expands it as a drop target

### Calendar
- View, create, update, and delete events
- Accept, tentatively accept, or decline meeting invitations
- Check attendee availability, with a side-by-side schedule pane for finding a
  free slot (see below)
- Propose new meeting times, and accept a proposed time as the organizer (moves the meeting and re-invites attendees)
- New meetings default to a 15-minute reminder
- Recurring event support, with per-occurrence or whole-series edit and cancel
- Editing a meeting you organize notifies attendees of the change
- Inline **Join** button on a meeting tile from 3 minutes before it starts until it ends, for meetings with a video-call link
- Guest RSVP status (accepted / declined / tentative) shown on each guest chip
- Timezone-aware scheduling
- Google Meet toggle for Gmail meetings
- Book meeting rooms directly from the event's Location field — booking invites the room as a resource, and only the invitation reserves it
- Hover a meeting tile to preview its full details without opening it
- Calendar opens to the working week by default, with hour gutters on both edges
- Meetings load instantly from a local cache while the calendar syncs in the background
- Supported backends: Microsoft Graph, Google Calendar, Nextcloud CalDAV, macOS/iOS EventKit
- Forwarded event invitations (calendar publishes, booking confirmations, tickets) are recognised, with an Add to calendar action
- The meeting invite/event-edit window reopens at the size and position it was last closed at
- Forward a meeting you were invited to on to someone else — joins the organiser's meeting where the provider supports it (Microsoft 365, and Google when the organiser allows guests to invite others), otherwise falls back to emailing the invitation

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
no availability until they're signed in again — use **Sign In Again** under
Settings → Accounts.

### Tasks
- Create and manage tasks across Microsoft To Do and Google Tasks
- Set due dates, importance, and status
- Notified when a task falls due, even if NightMail was closed at the time
- Tasks pane sorted by due date, earliest first, with undated tasks at the bottom
- Flag context menu offers business-day-aware due dates: Tomorrow, 3 Days, This Week and Next Week (resolving to the coming or following Friday)
- Attach emails to tasks (or link the source email in notes for providers without an attachment API)
- Expandable task notes with a link back to the source email — opens the email's conversation thread in the list pane
- Red dot on the Tasks icon when the active account has an overdue task

### Contacts
- Typeahead in the compose window drawing from three sources:
  - Previously known senders (local database)
  - System contacts (macOS Contacts app)
  - Organisational directory (Microsoft People API / Google Directory)

### Mobile
- Touch-sized icons and back-button navigation between panels on Android and iOS

### Accounts
- Multiple accounts from different providers simultaneously
- Per-account folder, calendar, and task views
- Secure token storage (system Keychain / encrypted preferences)
- Clear an account's local cache without removing the account
- **Sign In Again** (Settings → Accounts) re-runs the OAuth consent flow for a
  Microsoft 365 or Gmail account without deleting it or its cache. Needed when a
  new provider scope is added — providers won't grant one on a token refresh, so
  existing accounts have to re-consent. Cancelling is safe: the current token is
  left in place until a new one is issued.
- **Add Shared Mailbox** (Microsoft 365) adds a shared mailbox using the signed-in
  account's own permissions, with no separate sign-in
- **Migrate Account** copies mail from one configured account into another,
  mapping special folders by kind rather than name; resumable, with a status
  dialog reporting live progress and any permanent per-message failures

### Updates
- Checks for a new version at launch and every 6 hours, with a dot on the
  Settings icon when one is waiting; nothing downloads or installs until you
  press the button
- **macOS and Windows** download, verify and install the update in place, from
  a signed release archive
- **Android** installs the newest release's APK through the system installer
- **Linux** ships as a snap, which updates itself
- Release notes for the newest published version, grouped by change type, shown
  whether or not an update is pending

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
