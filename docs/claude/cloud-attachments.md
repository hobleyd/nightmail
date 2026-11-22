# Attaching and Linking Cloud Files

The compose editor's paperclip is a menu: **Attach from Computer**, **Attach
from Cloud**, **Link from Cloud**. See [../../CLAUDE.md](../../CLAUDE.md) for
architecture-wide rules, and [body-links.md](body-links.md) for the *receiving*
side (previewing a cloud link in a message), which shares the datasources and
the read scopes with this.

## Where Each Piece Lives

- **The menu is drawn inside `editor.html`**, not by Flutter. On the desktop
  the editor is a native webview laid over the Flutter surface, so a Flutter
  popup anchored to the toolbar would sit underneath it. The page posts
  `onAttachRequest` with `computer`/`cloudAttach`/`cloudLink`; the native
  bridges already carried a value, and `HtmlViewController.onAttachRequested`
  is now a `Stream<String>` so it reaches `AttachSource.fromPageValue`.
- **The picker** (`cloud_file_picker_dialog.dart`, `CloudFilePickerCubit`) is a
  Flutter dialog opened with the editor hidden (`ComposeFormState._overEditor`),
  like every other dialog the form opens. One picker for both purposes; it
  lists every signed-in account with a drive (`AccountManager.cloudFileSources`),
  the From account first.
- **Browse, download, permissions, share** are on `CloudDriveDatasource`,
  implemented by the same two classes that fetch previews:
  `GraphDriveDatasourceImpl` (Microsoft 365 *and* NightMail Server — Nightware
  serves the caller's Nextcloud home as `/me/drive`, its ADR 0008) and
  `GoogleDriveDatasourceImpl`. `CloudFileRepository` names its account
  explicitly — the sender chose which drive — unlike `CloudDriveRepository`,
  which picks an account for a link.
- **The send-time check** is `prepareCloudLinksForSend`
  (`compose_cloud_links.dart`), called from `_submit` after the body is final.

## Provider Differences

| | Microsoft 365 | NightMail Server | Google |
|---|---|---|---|
| Collections | My files, Shared with me | My files | My Drive, Shared with me, Shared drives |
| Search | `/search/query` (reaches SharePoint), falls back to `/me/drive/root/search` | `/me/drive/root/search` | `files.list name contains` |
| Read scope | `Files.Read.All` (incremental) | none — server's own scopes | `drive.readonly` (incremental) |
| Share scope | `Files.ReadWrite.All` (incremental) | none | `drive` (incremental) |
| Share call | `/invite`, `sendInvitation:false` | `/invite` (Nextcloud users only) | `permissions.create`, `sendNotificationEmail=false` |

- **Nightware answers `sharedWithMe` with 501** (and Microsoft is retiring it),
  so a server source offers My files only; the Graph datasource returns an
  empty list for it without asking.
- **A Google editor file is attached as its Office export** — Docs → `.docx`,
  Sheets → `.xlsx`, Slides → `.pptx`, Drawings → PDF — because the recipient
  may have no Google account. Google caps exports at 10 MB.
- **Attachments are capped at `cloudAttachmentMaxBytes` (20 MB)**, checked from
  the listing's size before downloading anything. Past that the error says to
  link it instead; base64 makes a 20 MB file ~27 MB on the wire, already over
  Gmail's limit-in-practice.
- **Google will not silently share with an address that has no Google
  account** (`invalidSharingRequest`); that one recipient is retried with
  Google's notification on.
- **Nightware's `/invite` only finds Nextcloud users.** An outside address
  comes back as a per-recipient failure, which is why sharing is one request
  per recipient on Graph: one refusal would otherwise fail the lot, and the
  sender needs to know who.

## Scopes Stay Incremental, and the Refresh Must Keep Them

Same rule as the preview's read scopes (body-links.md, the auth CLAUDE.md):
nothing new goes in a base scope list. Browsing asks for the read scope on the
picker's "Grant access" button (`requestCloudDriveAccess`, the same flow the
reading pane uses); sharing asks for the write scope only when the sender
presses **Share and send** (`requestCloudDriveShareAccess`).

**`Files.Read` is a prefix of `Files.ReadWrite`.** `grantsFileAccess` is a
substring test and is still true for a write-only token, which is right for
"can read files" but wrong for a refresh: re-requesting `Files.Read.All` on a
token consented only to `Files.ReadWrite.All` fails the refresh. So
`_refreshScopes` adds each file scope only on an *exact* token match, and the
share grant asks for both scopes together so the read one is never lost.
Pinned by `cloud_drive_share_scope_test.dart`.

## The Access Check Happens at Send, Not at Insert

A link usually goes in before the To line is finished, and the recipient added
last is exactly the one who would be missed. So the compose form only records
`url → CloudFile` (`_cloudLinks`) when it inserts a link, and `_submit` checks
the links still present in the body against To + Cc + Bcc. It is in memory
only — a draft reopened later sends its links unchecked.

- **No provider has a "can this address open it" call**, so
  `CloudFileAccessMatcher` reads the permission list: anyone-links cover all,
  an organization link or Drive `domain` permission covers that domain, a user
  grant or pending invitation covers that address. **A group grant (SharePoint
  site group, Entra/Google group) is taken to cover internal recipients but
  never outside ones** — otherwise every link to a team-site file prompted for
  every colleague, and the sender learns to click through the prompt.
- **When the provider will not list the permissions** (the sender is only a
  reader — 403), there is nothing to report *and* nothing they could share, so
  the link goes without a prompt (`canShare: false`).
- **A failed check never holds the message.** Offline or a provider error is
  logged as `[CloudFiles]` and the link goes as it is.
- **An existing anyone-with-the-link URL replaces the inserted link** at send:
  a OneDrive/SharePoint `webUrl` does not open for someone holding only an
  anonymous link, the sharing URL does.
- **Share and send stops on any failure** with the reasons in the notice strip,
  rather than sending a link someone cannot open. Sending again re-checks, so
  only the recipients still without access are asked about, and **Send anyway**
  is there.
