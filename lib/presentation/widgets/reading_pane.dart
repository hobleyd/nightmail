import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_selector/file_selector.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email.dart';
import '../../domain/entities/email_attachment.dart';
import '../../domain/usecases/delete_email.dart';
import '../../domain/usecases/download_attachment.dart';
import '../../domain/usecases/send_email.dart';
import '../../injection_container.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_detail/email_detail_state.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import 'compose_dialog.dart';
import 'email_date_formatter.dart';

class ReadingPane extends StatelessWidget {
  const ReadingPane({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfaceReading,
      child: BlocBuilder<EmailDetailBloc, EmailDetailState>(
        builder: (context, state) {
          return switch (state) {
            EmailDetailInitial() => const _EmptyState(),
            EmailDetailLoading() => Center(
                child: CircularProgressIndicator(
                    color: AppColors.accent, strokeWidth: 2),
              ),
            EmailDetailLoaded(:final email) => _EmailView(email: email),
            EmailDetailError(:final message) => _ErrorState(message: message),
          };
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mark_email_read_outlined,
              size: 48, color: c.stateIcon),
          const SizedBox(height: 16),
          Text(
            'Select an email to read',
            style: TextStyle(color: c.stateText, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, color: c.textMuted, size: 36),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmailView extends StatelessWidget {
  const _EmailView({required this.email});
  final Email email;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReadingPaneToolbar(email: email),
        Divider(height: 1, color: c.border),
        _EmailHeader(email: email),
        Divider(height: 1, color: c.border),
        Expanded(
          child: _EmailBody(email: email),
        ),
      ],
    );
  }
}

class _ReadingPaneToolbar extends StatelessWidget {
  const _ReadingPaneToolbar({required this.email});
  final Email email;

  Future<void> _confirmAndDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete email', style: TextStyle(fontSize: 15)),
        content: const Text(
          'Move this email to Deleted Items?',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final result =
        await sl<DeleteEmail>()(DeleteEmailParams(id: email.id));

    if (!context.mounted) return;

    result.fold(
      (f) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(f.message)),
      ),
      (_) {
        context.read<EmailDetailBloc>().add(const EmailDetailCleared());
        context.read<EmailListBloc>().add(
              EmailListEmailDeleted(emailId: email.id),
            );
      },
    );
  }

  Future<void> _copyToClipboard(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: email.body));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Email body copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          _ToolbarButton(
            icon: Icons.reply_rounded,
            tooltip: 'Reply',
            color: c.textMuted,
            onPressed: () => ComposeDialog.show(
              context,
              mode: ComposeMode.reply,
              originalEmail: email,
            ),
          ),
          _ToolbarButton(
            icon: Icons.reply_all_rounded,
            tooltip: 'Reply All',
            color: c.textMuted,
            onPressed: () => ComposeDialog.show(
              context,
              mode: ComposeMode.replyAll,
              originalEmail: email,
            ),
          ),
          _ToolbarButton(
            icon: Icons.forward_to_inbox_rounded,
            tooltip: 'Forward',
            color: c.textMuted,
            onPressed: () => ComposeDialog.show(
              context,
              mode: ComposeMode.forward,
              originalEmail: email,
            ),
          ),
          const Spacer(),
          _ToolbarButton(
            icon: Icons.content_copy_outlined,
            tooltip: 'Debug: copy body to clipboard',
            color: c.textMuted,
            onPressed: () => _copyToClipboard(context),
          ),
          _ToolbarButton(
            icon: Icons.delete_outline_rounded,
            tooltip: 'Delete',
            color: c.textMuted,
            onPressed: () => _confirmAndDelete(context),
          ),
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16, color: color),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: onPressed,
    );
  }
}

class _EmailHeader extends StatelessWidget {
  const _EmailHeader({required this.email});
  final Email email;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            email.subject,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 16),
          _MetaRow(
            icon: Icons.person_outline_rounded,
            label: 'From',
            value: '${email.from.displayName} <${email.from.address}>',
          ),
          if (email.toRecipients.isNotEmpty) ...[
            const SizedBox(height: 6),
            _MetaRow(
              icon: Icons.mail_outline_rounded,
              label: 'To',
              value: email.toRecipients
                  .map((r) => r.displayName)
                  .join(', '),
            ),
          ],
          if (email.ccRecipients.isNotEmpty) ...[
            const SizedBox(height: 6),
            _MetaRow(
              icon: Icons.people_outline_rounded,
              label: 'Cc',
              value: email.ccRecipients
                  .map((r) => r.displayName)
                  .join(', '),
            ),
          ],
          const SizedBox(height: 6),
          _MetaRow(
            icon: Icons.schedule_rounded,
            label: 'Date',
            value: formatEmailDateLong(email.receivedDateTime),
          ),
          if (email.attachments.isNotEmpty) ...[
            const SizedBox(height: 10),
            _AttachmentsSection(
              emailId: email.id,
              attachments: email.attachments,
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: c.textDimmed),
        const SizedBox(width: 6),
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: TextStyle(
              color: c.textDimmed,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: c.textTertiary,
              fontSize: 12,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _AttachmentsSection extends StatelessWidget {
  const _AttachmentsSection({
    required this.emailId,
    required this.attachments,
  });
  final String emailId;
  final List<EmailAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.attach_file_rounded, size: 14, color: c.textDimmed),
        const SizedBox(width: 6),
        SizedBox(
          width: 44,
          child: Text(
            'Files',
            style: TextStyle(
              color: c.textDimmed,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: attachments
                    .map((a) =>
                        _AttachmentChip(emailId: emailId, attachment: a))
                    .toList(),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: _SaveAllButton(
                  emailId: emailId,
                  attachments: attachments,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SaveAllButton extends StatefulWidget {
  const _SaveAllButton({required this.emailId, required this.attachments});
  final String emailId;
  final List<EmailAttachment> attachments;

  @override
  State<_SaveAllButton> createState() => _SaveAllButtonState();
}

class _SaveAllButtonState extends State<_SaveAllButton> {
  bool _isLoading = false;

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _saveAll() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      if (_isMobile) {
        await _saveAllMobile();
      } else {
        await _saveAllDesktop();
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveAllDesktop() async {
    final directory = await getDirectoryPath();
    if (directory == null || !mounted) return;

    final results = await Future.wait(
      widget.attachments.map((a) async {
        final r = await sl<DownloadAttachment>()(DownloadAttachmentParams(
          messageId: widget.emailId,
          attachmentId: a.id,
        ));
        return (attachment: a, either: r);
      }),
    );
    if (!mounted) return;

    final errors = <String>[];
    final writes = <Future<void>>[];
    for (final (:attachment, :either) in results) {
      either.fold(
        (f) => errors.add('${attachment.name}: ${f.message}'),
        (bytes) => writes.add(
          File('$directory/${attachment.name}')
              .writeAsBytes(bytes)
              .catchError((Object e) => errors.add('${attachment.name}: $e')),
        ),
      );
    }
    await Future.wait(writes);
    if (!mounted) return;

    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save:\n${errors.join('\n')}')),
      );
    }
  }

  Future<void> _saveAllMobile() async {
    final dir = await getTemporaryDirectory();

    final results = await Future.wait(
      widget.attachments.map((a) async {
        final r = await sl<DownloadAttachment>()(DownloadAttachmentParams(
          messageId: widget.emailId,
          attachmentId: a.id,
        ));
        return (attachment: a, either: r);
      }),
    );
    if (!mounted) return;

    final errors = <String>[];
    final xFiles = <XFile>[];
    final writes = <Future<void>>[];
    for (final (:attachment, :either) in results) {
      either.fold(
        (f) => errors.add(attachment.name),
        (bytes) {
          final path = '${dir.path}/${attachment.name}';
          writes.add(File(path).writeAsBytes(bytes));
          xFiles.add(XFile(path, mimeType: attachment.contentType));
        },
      );
    }
    await Future.wait(writes);
    if (!mounted) return;

    if (xFiles.isNotEmpty) {
      await SharePlus.instance.share(ShareParams(files: xFiles));
    }
    if (errors.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to download: ${errors.join(', ')}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: _saveAll,
      child: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading)
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.accent,
                ),
              )
            else
              Icon(Icons.save_alt_rounded, size: 11, color: c.textMuted),
            const SizedBox(width: 3),
            Text(
              'Save all',
              style: TextStyle(color: c.textMuted, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentChip extends StatefulWidget {
  const _AttachmentChip({required this.emailId, required this.attachment});
  final String emailId;
  final EmailAttachment attachment;

  @override
  State<_AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends State<_AttachmentChip> {
  bool _isLoading = false;

  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static IconData _iconFor(String contentType, String name) {
    final ct = contentType.toLowerCase();
    final ext =
        name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (ct.startsWith('image/')) { return Icons.image_rounded; }
    if (ct.contains('pdf') || ext == 'pdf') { return Icons.picture_as_pdf_rounded; }
    if (ct.contains('word') || ext == 'doc' || ext == 'docx') { return Icons.description_rounded; }
    if (ct.contains('excel') || ct.contains('spreadsheet') ||
        ext == 'xls' || ext == 'xlsx' || ext == 'csv') { return Icons.table_chart_rounded; }
    if (ct.contains('powerpoint') || ct.contains('presentation') ||
        ext == 'ppt' || ext == 'pptx') { return Icons.slideshow_rounded; }
    if (ct.contains('zip') || ct.contains('archive') ||
        ext == 'zip' || ext == 'rar' || ext == '7z') { return Icons.folder_zip_rounded; }
    if (ct.startsWith('audio/')) { return Icons.audio_file_rounded; }
    if (ct.startsWith('video/')) { return Icons.video_file_rounded; }
    return Icons.attach_file_rounded;
  }

  Future<void> _withBytes(Future<void> Function(List<int> bytes) action) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      final result = await sl<DownloadAttachment>()(DownloadAttachmentParams(
        messageId: widget.emailId,
        attachmentId: widget.attachment.id,
      ));
      if (!mounted) return;
      await result.fold(
        (failure) async {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not download: ${failure.message}')),
          );
        },
        action,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _open() => _withBytes((bytes) async {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/${widget.attachment.name}');
        await file.writeAsBytes(bytes);
        await OpenFile.open(file.path);
      });

  Future<void> _saveAs() => _withBytes((bytes) async {
        if (_isMobile) {
          // Mobile: share sheet lets the user pick Files / Downloads
          final dir = await getTemporaryDirectory();
          final tmp = File('${dir.path}/${widget.attachment.name}');
          await tmp.writeAsBytes(bytes);
          await SharePlus.instance.share(ShareParams(
            files: [XFile(tmp.path, mimeType: widget.attachment.contentType)],
          ));
        } else {
          // Desktop: native save-as dialog
          final location = await getSaveLocation(
            suggestedName: widget.attachment.name,
          );
          if (location != null) {
            await File(location.path).writeAsBytes(bytes);
          }
        }
      });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: _isMobile ? _open : null,
      onDoubleTap: _isMobile ? null : _open,
      onLongPress: _isMobile ? _saveAs : null,
      onSecondaryTap: _isMobile ? null : _saveAs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: c.badgeBg,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.accent,
                ),
              )
            else
              Icon(
                _iconFor(widget.attachment.contentType, widget.attachment.name),
                size: 12,
                color: c.textMuted,
              ),
            const SizedBox(width: 4),
            Text(
              widget.attachment.name,
              style: TextStyle(color: c.textTertiary, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmailBody extends StatelessWidget {
  const _EmailBody({required this.email});
  final Email email;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    if (email.bodyType == EmailBodyType.html) {
      return _HtmlBodyWebView(html: email.body);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
      child: SelectableText(
        email.body,
        style: TextStyle(
          color: c.textBody,
          fontSize: 14,
          height: 1.6,
        ),
      ),
    );
  }
}

class _HtmlBodyWebView extends StatefulWidget {
  const _HtmlBodyWebView({required this.html});
  final String html;

  @override
  State<_HtmlBodyWebView> createState() => _HtmlBodyWebViewState();
}

class _HtmlBodyWebViewState extends State<_HtmlBodyWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setNavigationDelegate(NavigationDelegate(
        // Allow the initial HTML load (about:, data:, file:) but block any
        // outbound http/https navigation triggered by clicking links.
        onNavigationRequest: (request) {
          final scheme = Uri.tryParse(request.url)?.scheme ?? '';
          if (scheme == 'http' || scheme == 'https') {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadHtmlString(_wrapHtml(widget.html));
  }

  @override
  void didUpdateWidget(_HtmlBodyWebView old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) {
      _controller.loadHtmlString(_wrapHtml(widget.html));
    }
  }

  static String _wrapHtml(String html) {
    // Inject viewport + minimal responsive overrides before </head>.
    // Using a real WKWebView means !important works and table layout is correct.
    const injected = '''
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0">
<style>
* { box-sizing: border-box !important; }
body { margin: 0; padding: 20px 28px 40px; }
img { max-width: 100% !important; height: auto !important; }
</style>
''';
    final headEnd = html.indexOf('</head>');
    if (headEnd != -1) {
      return html.substring(0, headEnd) + injected + html.substring(headEnd);
    }
    return '<html><head>$injected</head><body>$html</body></html>';
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
