/// What counts as a markdown file — one rule, shared by the attachment chips
/// (which decide whether a chip opens the rendered preview) and by
/// `cloudDocumentFormatFor` (which decides the same thing for a link to
/// somebody's drive). Keeping them apart is how the same file comes to look
/// like two different things in one pane depending on where it arrived from.
library;

/// The extensions that name a markdown file. `txt` is deliberately absent — a
/// text attachment is shown as it was written, and claiming it here would
/// swallow its blank lines and turn every `*` into a bullet.
const markdownExtensions = <String>{'md', 'markdown', 'mdown', 'mkd', 'mkdn'};

/// Whether [name]/[contentType] name a markdown file, and so belong in the
/// rendered preview rather than the raw one.
///
/// **The extension decides, and a bare `text/plain` is not a claim.** A `.md`
/// file routinely arrives typed `text/plain` or `application/octet-stream` —
/// no provider looks inside it — so the content type can only ever add to what
/// the name says. Reading it the other way round would make every `.txt`
/// attachment markdown.
bool isMarkdownFile({required String name, String? contentType}) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (markdownExtensions.contains(ext)) return true;
  final ct = (contentType ?? '').toLowerCase();
  return ct.contains('text/markdown') || ct.contains('text/x-markdown');
}
