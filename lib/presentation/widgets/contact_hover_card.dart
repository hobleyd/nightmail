import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html_view/html_view.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/contact_details.dart';
import '../../domain/usecases/get_contact_details.dart';
import '../../injection_container.dart';

/// Wraps a recipient chip so hovering it fetches and shows a contact-details
/// card (job title, department, phone, etc.) via [GetContactDetails], with a
/// copy-icon button per field and a compose button at the foot.
///
/// Only Gmail and Microsoft accounts can serve details; on the others the
/// card still appears, carrying the address and the compose button, so every
/// address in a header offers the same actions.
class ContactHoverTarget extends StatefulWidget {
  const ContactHoverTarget({
    super.key,
    required this.address,
    required this.accountId,
    required this.onCompose,
    required this.child,
  });

  final String address;
  final String accountId;

  /// Invoked by the card's compose button. Supplied by the caller so this
  /// widget stays out of the compose-window plumbing, and so the callback
  /// runs against a context that outlives the card's overlay.
  final VoidCallback onCompose;

  final Widget child;

  @override
  State<ContactHoverTarget> createState() => _ContactHoverTargetState();
}

class _ContactHoverTargetState extends State<ContactHoverTarget> {
  final _layerLink = LayerLink();
  final _overlayController = OverlayPortalController();
  Timer? _showTimer;
  Timer? _hideTimer;
  Future<ContactDetails?>? _future;
  bool _guardAcquired = false;

  @override
  void dispose() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _releaseGuard();
    super.dispose();
  }

  void _releaseGuard() {
    if (_guardAcquired) {
      HtmlViewOverlayGuard.release();
      _guardAcquired = false;
    }
  }

  void _scheduleShow() {
    _hideTimer?.cancel();
    _showTimer?.cancel();
    _showTimer = Timer(const Duration(milliseconds: 400), () {
      _future ??= sl<GetContactDetails>().call(
        address: widget.address,
        accountId: widget.accountId,
      );
      if (mounted && !_overlayController.isShowing) {
        HtmlViewOverlayGuard.acquire();
        _guardAcquired = true;
        _overlayController.show();
      }
    });
  }

  void _cancelHide() => _hideTimer?.cancel();

  void _scheduleHide() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 150), () => _hideNow());
  }

  void _hideNow() {
    _showTimer?.cancel();
    _hideTimer?.cancel();
    if (mounted && _overlayController.isShowing) {
      _overlayController.hide();
      _releaseGuard();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: OverlayPortal(
        controller: _overlayController,
        overlayChildBuilder: (ctx) => Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 4),
            child: MouseRegion(
              onEnter: (_) => _cancelHide(),
              onExit: (_) => _scheduleHide(),
              child: _ContactDetailsCard(
                future: _future,
                address: widget.address,
                onCompose: () {
                  _hideNow();
                  widget.onCompose();
                },
              ),
            ),
          ),
        ),
        child: MouseRegion(
          onEnter: (_) => _scheduleShow(),
          onExit: (_) => _scheduleHide(),
          child: widget.child,
        ),
      ),
    );
  }
}

class _ContactDetailsCard extends StatelessWidget {
  const _ContactDetailsCard({
    required this.future,
    required this.address,
    required this.onCompose,
  });

  final Future<ContactDetails?>? future;

  /// The address hovered, shown when the lookup returns no details of its own
  /// (an IMAP account, or a sender who isn't in the directory).
  final String address;

  final VoidCallback onCompose;

  Future<void> _copy(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copied to clipboard'),
          duration: Duration(milliseconds: 1200),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.surfacePanel,
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.border),
        ),
        child: FutureBuilder<ContactDetails?>(
          future: future,
          builder: (ctx, snapshot) {
            if (future == null ||
                snapshot.connectionState == ConnectionState.waiting) {
              // Center loosens the card's minWidth:220 constraint before it
              // reaches the SizedBox — otherwise the spinner is forced to the
              // full card width and renders as an elongated ellipse.
              return const Center(
                heightFactor: 1,
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      color: AppColors.accent, strokeWidth: 2),
                ),
              );
            }
            final details = snapshot.data;
            return _buildContent(context, c, details);
          },
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, AppColors c, ContactDetails? details) {
    final rows = <Widget>[];

    void addField(String label, String? value) {
      if (value == null || value.isEmpty) return;
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 6));
      rows.add(_FieldRow(
        label: label,
        value: value,
        onCopy: () => _copy(context, value),
      ));
    }

    final photo = _photoWidget(details);
    if (photo != null) {
      rows.add(Center(child: photo));
      rows.add(const SizedBox(height: 8));
    }

    addField('Name', details?.name);
    addField('Email', details?.address ?? address);
    addField('Title', details?.jobTitle);
    addField('Department', details?.department);
    addField('Company', details?.companyName);
    addField('Office', details?.officeLocation);
    final phones = details?.phoneNumbers ?? const [];
    for (var i = 0; i < phones.length; i++) {
      addField(phones.length > 1 ? 'Phone ${i + 1}' : 'Phone', phones[i]);
    }

    rows.add(const SizedBox(height: 8));
    rows.add(Divider(height: 1, thickness: 1, color: c.separator));
    rows.add(const SizedBox(height: 6));
    rows.add(Center(child: _ComposeIconButton(onCompose: onCompose)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  Widget? _photoWidget(ContactDetails? details) {
    final bytes = details?.photoBytes;
    final url = details?.photoUrl;
    if (bytes == null && (url == null || url.isEmpty)) return null;
    final image = bytes != null
        ? Image.memory(bytes, width: 40, height: 40, fit: BoxFit.cover)
        : Image.network(url!, width: 40, height: 40, fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink());
    return ClipOval(child: image);
  }
}

class _FieldRow extends StatefulWidget {
  const _FieldRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  State<_FieldRow> createState() => _FieldRowState();
}

class _FieldRowState extends State<_FieldRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: _hovering ? c.separator : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: c.textDimmed,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    widget.value,
                    style: TextStyle(color: c.textPrimary, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            _CopyIconButton(onCopy: widget.onCopy),
          ],
        ),
      ),
    );
  }
}

/// Deliberately not a Material [IconButton]/[Tooltip] — those install their
/// own hover timer/OverlayEntry, which can throw ("Looking up a deactivated
/// widget's ancestor is unsafe") if the mouse leaves this icon right as the
/// hover card's own overlay is torn down and the tooltip tries to show/hide
/// against a now-deactivated context.
class _CopyIconButton extends StatefulWidget {
  const _CopyIconButton({required this.onCopy});

  final VoidCallback onCopy;

  @override
  State<_CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<_CopyIconButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onCopy,
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovering ? c.separatorStrong : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(Icons.copy_rounded, size: 13, color: c.textDimmed),
        ),
      ),
    );
  }
}

/// The card's one action: write a new email to this contact. Bigger than the
/// per-field copy buttons because it acts on the whole card, and hand-rolled
/// for the same reason [_CopyIconButton] is.
class _ComposeIconButton extends StatefulWidget {
  const _ComposeIconButton({required this.onCompose});

  final VoidCallback onCompose;

  @override
  State<_ComposeIconButton> createState() => _ComposeIconButtonState();
}

class _ComposeIconButtonState extends State<_ComposeIconButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onCompose,
        child: Container(
          width: 36,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovering ? c.separatorStrong : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            Icons.mail_outline_rounded,
            size: 20,
            color: _hovering ? AppColors.accent : c.textSecondary,
          ),
        ),
      ),
    );
  }
}
