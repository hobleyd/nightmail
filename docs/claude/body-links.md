# Body Link Handling

How `openBodyLink` (`presentation/widgets/body_link_opener.dart`) routes `mailto:` and cloud-document links. See [../../CLAUDE.md](../../CLAUDE.md) for architecture-wide rules.

## A mailto: Link Is Answered Here, Not by the OS

Every body link goes to `launchUrl` except `mailto:`, which `openBodyLink`
(`presentation/widgets/body_link_opener.dart`) sends to
`ComposeWindowApp.openMailto` — the same entry point the OS uses when another
app hands NightMail a `mailto:` URI. `bcc=` is dropped: nothing downstream
carries a BCC list.

## A Cloud Document Link Is Previewed, Not Followed

A SharePoint/OneDrive or Google Drive link — or, on a NightMail Server, a link
to its Nextcloud — in a body is an attachment in all but name, so
`openBodyLink` fetches it and draws it in the reading pane's preview surface —
the same one the attachment chips use — instead of handing it to a browser
that would ask the reader to sign in to a second thing to read their own mail. Everything else still goes to `launchUrl`.

**Which mailbox the mail arrived in says nothing about who holds the file.** A
OneDrive link turns up in Gmail and a Drive link in Exchange as a matter of
course, so the provider is read off the *URL* (`CloudDocumentLink.provider`) and
`CloudDriveRepositoryImpl` then picks an account signed in to *that* service,
active account first, trying each in turn — two tenants, and only one of them
was shared the file.

Five things here are load-bearing:

- **The scanner is biased towards not matching.** A false positive is the
  expensive mistake: a SharePoint *site* link or a Drive *folder* link opens
  fine in a browser today, and claiming it replaces that with a spinner and an
  apology. So `/:f:/`, `/_layouts/`, `.aspx`, `/Lists/`, site roots,
  `/drive/folders/`, `/forms/` and published `/d/e/` documents are excluded by
  name, consumer OneDrive (`1drv.ms`, `onedrive.live.com`) is deliberately not
  claimed at all, and anything unrecognised falls through unchanged.
- **The file scopes are requested incrementally, never at sign-in.** Neither
  `Files.Read.All` nor `drive.readonly` may go in `_scopes`: an authorization
  request naming a scope nobody has consented to fails *outright* — Microsoft
  AADSTS65001 where a tenant reserves `Files.Read.All` for admin consent, and
  Google treats `drive.readonly` as a restricted scope — so the casualty would
  be **adding a mail account**, over a feature that account may never use. Same
  reasoning as `GmailAuthService._roomDirectoryScope`, one step further.
  `AccountManager.requestCloudDriveAccess` runs the flow that asks, on a prompt,
  when a reader first follows a cloud link. `Sites.Read.All` is not requested
  either: the sharing-link route does not need it, and it is the scope most
  likely to need an administrator.
- **The granted scope lives on the token, and a Microsoft refresh must re-ask
  for it.** Both providers echo granted scopes back on every token and refresh
  response, so `AuthToken.scope` *is* the record of the grant and there is no
  flag to fall out of step with it (`grantsFileAccess`). But a Microsoft refresh
  names the scopes it wants: refreshing with the base list alone would hand back
  a token *without* file access an hour after the grant, which would read as the
  permission lapsing. `_refreshScopes` adds it back only when the token proves
  it was consented to — asking for an unconsented scope fails the refresh.
  Google's refresh takes no scope, but its authorization request needs
  `include_granted_scopes=true`, or the flow comes back holding Drive access
  *instead of* the mail scopes.
- **A pre-authenticated URL must not carry an `Authorization` header.** Graph
  answers `/driveItem/content` with a 302 to a short-lived signed blob URL that
  refuses a request carrying credentials as well ("only one authentication
  mechanism allowed"), so `GraphDriveDatasourceImpl` sets
  `followRedirects: false` and fetches the `Location` with a *separate,
  interceptor-free* Dio. Reusing the Graph client — whose `AuthInterceptor` adds
  the header to everything it sees — is exactly the failure.
- **Falling back is the normal case, not the error path.**
  `CloudDocumentPreviewHost.onPreview` returning false means "open it in the
  browser after all", and covers no account, a declined permission, a file type
  that cannot be drawn, a document too large, and mobile (whose preview
  surfaces are the desktop native webview). Only a *server or network* failure
  says anything on screen; the rest just behave as the link did before. The
  standalone email window publishes no host at all, which is why a link there
  still opens in the browser.

Office formats come back as a **server-rendered PDF** (Graph
`content?format=pdf`, Drive `files/{id}/export?mimeType=application/pdf`):
higher fidelity than the bundled JS viewer and it needs no LibreOffice on the
machine. `OfficePreviewService` is the fallback, for the one case the providers
will not convert — an *uploaded* Office file in Drive, which needs write access
to copy-and-export. Google editor files have no bytes of their own and are only
ever an export, capped at 10 MB by Google. `CloudDocument.convertedToPdf` is
what tells the preview to treat a document titled `.docx` as the PDF it now is;
`cloudDocumentFormatFor` (`core/utils/cloud_document_format.dart`) is the one
rule both the datasources and the pane read, so a file is never downloaded and
*then* found to be unpreviewable.

## A NightMail Server's Nextcloud Links Take the SharePoint Route

A NightMail Server (Nightware) fronts a Nextcloud, and a link to a document on
it previews exactly as a SharePoint link does on Microsoft 365: through the
server's Graph `/shares/{u!url}/driveItem` and `/content?format=pdf`, fetched
by `GraphDriveDatasourceImpl` against that account's own Graph base. The server
answers `/content` with a 302 to a short-lived self-authorising URL — the same
pre-authenticated-download dance, so the interceptor-free Dio is load-bearing
here too — and renders Office files to PDF with Collabora.

- **Only advertised hosts are claimed.** The scanner has no idea which hosts
  are Nextclouds, and `/s/{token}` is too generic a shape to claim on sight.
  A server lists its file sites in discovery (`filesBaseUrls`, optional —
  `GraphEndpointsModel` drops a malformed entry rather than refusing the
  server), `AccountManager.nextcloudFileBaseUrls` collects them across signed-in
  servers, and `parseCloudDocumentLink` takes them as `nextcloudBaseUrls`. Only
  `{base}/s/{token}` and `{base}/f/{fileId}` (with or without `index.php/`)
  match; the Files app, a share's `/download`, and anything with a query or
  fragment stay with the browser.
- **The account is the server that advertises the host**
  (`cloudDriveCandidates(nextcloud, url:)`), never another server — two
  servers' Nextclouds share nothing, so asking the wrong one is a certain 404.
  There is no scope to grant: `hasCloudDriveAccess` is simply "does it publish
  file sites".
- **403/404 fall through quietly.** On a Nextcloud they are the share itself
  saying no — password-protected, deleted, or an internal `/f/` link to a file
  never shared with this reader — and the browser can do what NightMail cannot
  (ask for the password, offer a login). So the repository reports them as
  `CloudDriveUnavailable`, not `ServerFailure`; Microsoft's 403/404 handling is
  unchanged. A folder share comes back as a `folder` and falls back the same way.
- **The file sites are re-learnt, and a failure to is never silent.**
  `AccountCubit` asks each server again at startup
  (`AccountManager.refreshServerFileSites`), so an account added before its
  server published file sites gets them without being re-added. Each server's
  outcome (`FileSitesRefresh`: updated, unchanged, unreachable, refused) is
  logged as a `[FileSites]` line. Every one of them used to end in a bare
  `continue`, and on 2026-11-19 a `/f/` link opened in the browser for a whole
  session with nothing recorded to say why — it previewed after the next
  restart. So a click on a link at the host of a server whose accounts hold
  *no* file sites (`serverWithoutFileSitesAt`) asks that server again, once,
  before giving up, and re-matches the link; if it still cannot, a snack bar
  says whether the server was unreachable or *refused* — moved its sign-in
  settings, which only re-adding the account fixes and which never clears on
  its own. Every click also leaves `[CloudPreview]` lines saying where it
  stopped.

Microsoft and Google accounts are untouched by all of this.

**The preview bar's title is the way back to the file.** Drawing the document
here is *instead of* the browser tab the reader clicked, so the header
(`_PreviewHeader`) carries the source URL and opens it externally on a tap —
otherwise previewing a document would be the one thing that took away the
ability to comment on it, edit it or share it on. It calls `launchUrl`
directly rather than `openBodyLink`: the header is drawn **inside** the
`CloudDocumentPreviewHost` the pane publishes, so going through the opener
would match the link, find that host, and fetch the document again instead of
leaving the app. `_previewSourceUrl` is assigned on every `_showPreview`,
including the attachment paths that pass none — a preview opened after a cloud
document would otherwise inherit its link and offer the wrong file. The title
underlines only under the pointer, so an `open_in_new` icon beside the close
button carries the same tap: a reader who never hovers the exact text would
otherwise never learn the link is there.

