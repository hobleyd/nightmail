import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/cloud_document.dart';
import '../../domain/entities/cloud_file.dart';
import '../../domain/usecases/cloud_files.dart';
import '../../infrastructure/accounts/account_manager.dart';
import '../../injection_container.dart';
import '../blocs/cloud_file_picker/cloud_file_picker_cubit.dart';

/// What the picker's files are for, which decides its title and its button.
enum CloudFilePickerPurpose { attach, link }

/// The compose window's cloud counterpart of the system file picker: browse
/// any signed-in account's drive (Microsoft 365, Google Drive, a NightMail
/// Server's Nextcloud) and pick one or more files. Returns null on cancel.
///
/// [preferredAccountId] — the account the message is from — is browsed first.
Future<List<CloudFile>?> showCloudFilePicker(
  BuildContext context, {
  required CloudFilePickerPurpose purpose,
  String? preferredAccountId,
}) {
  return showDialog<List<CloudFile>>(
    context: context,
    builder: (_) => BlocProvider(
      create: (_) => CloudFilePickerCubit(
        accountManager: sl<AccountManager>(),
        listFiles: sl<ListCloudFiles>(),
        searchFiles: sl<SearchCloudFiles>(),
        preferredAccountId: preferredAccountId,
      )..load(),
      child: _CloudFilePickerDialog(purpose: purpose),
    ),
  );
}

class _CloudFilePickerDialog extends StatefulWidget {
  const _CloudFilePickerDialog({required this.purpose});

  final CloudFilePickerPurpose purpose;

  @override
  State<_CloudFilePickerDialog> createState() => _CloudFilePickerDialogState();
}

class _CloudFilePickerDialogState extends State<_CloudFilePickerDialog> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _confirm(List<CloudFile> selected) {
    if (selected.isNotEmpty) Navigator.of(context).pop(selected);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final size = MediaQuery.sizeOf(context);
    final phone = size.width < 600;
    final title = widget.purpose == CloudFilePickerPurpose.attach
        ? 'Attach from Cloud'
        : 'Link from Cloud';

    final body = BlocBuilder<CloudFilePickerCubit, CloudFilePickerState>(
      builder: (context, state) {
        final cubit = context.read<CloudFilePickerCubit>();
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              title: title,
              phone: phone,
              state: state,
              searchController: _searchController,
            ),
            Divider(height: 1, color: c.separator),
            Expanded(
              child: phone
                  ? _FileArea(purpose: widget.purpose, onConfirm: _confirm)
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 220, child: _SourceList(state: state)),
                        VerticalDivider(width: 1, color: c.separator),
                        Expanded(
                          child: _FileArea(
                              purpose: widget.purpose, onConfirm: _confirm),
                        ),
                      ],
                    ),
            ),
            Divider(height: 1, color: c.separator),
            _Footer(
              purpose: widget.purpose,
              selected: state.selected,
              onClear: state.selected.isEmpty
                  ? null
                  : () {
                      for (final f in [...state.selected]) {
                        cubit.toggle(f);
                      }
                    },
              onConfirm: () => _confirm(state.selected),
            ),
          ],
        );
        return content;
      },
    );

    if (phone) {
      return Dialog.fullscreen(backgroundColor: c.surfacePanel, child: body);
    }
    return Dialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: SizedBox(
        width: (size.width - 80).clamp(560.0, 860.0),
        height: (size.height - 80).clamp(380.0, 600.0),
        child: body,
      ),
    );
  }
}

String _providerLabel(CloudDriveProvider provider) => switch (provider) {
      CloudDriveProvider.microsoft => 'OneDrive & SharePoint',
      CloudDriveProvider.google => 'Google Drive',
      CloudDriveProvider.nextcloud => 'NightMail Server',
    };

String _collectionLabel(CloudFileCollection collection) =>
    switch (collection) {
      CloudFileCollection.myFiles => 'My files',
      CloudFileCollection.sharedWithMe => 'Shared with me',
      CloudFileCollection.sharedDrives => 'Shared drives',
    };

IconData _collectionIcon(CloudFileCollection collection) =>
    switch (collection) {
      CloudFileCollection.myFiles => Icons.folder_outlined,
      CloudFileCollection.sharedWithMe => Icons.folder_shared_outlined,
      CloudFileCollection.sharedDrives => Icons.storage_outlined,
    };

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.phone,
    required this.state,
    required this.searchController,
  });

  final String title;
  final bool phone;
  final CloudFilePickerState state;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cubit = context.read<CloudFilePickerCubit>();
    final canSearch = state.source?.hasReadAccess ?? false;
    final search = SizedBox(
      height: 34,
      child: TextField(
        controller: searchController,
        enabled: canSearch,
        style: TextStyle(color: c.textPrimary, fontSize: 13),
        textInputAction: TextInputAction.search,
        onSubmitted: cubit.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search files',
          hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
          prefixIcon: Icon(Icons.search, size: 18, color: c.textMuted),
          suffixIcon: state.searching
              ? IconButton(
                  tooltip: 'Clear search',
                  icon: Icon(Icons.close, size: 16, color: c.textMuted),
                  onPressed: () {
                    searchController.clear();
                    cubit.search('');
                  },
                )
              : null,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!phone) SizedBox(width: 260, child: search),
              IconButton(
                tooltip: 'Close',
                icon: Icon(Icons.close, size: 18, color: c.textTertiary),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          if (phone) ...[
            const SizedBox(height: 8),
            _SourceDropdown(state: state),
            const SizedBox(height: 8),
            Padding(padding: const EdgeInsets.only(right: 8), child: search),
          ],
        ],
      ),
    );
  }
}

/// Desktop: every account with its collections, down the left.
class _SourceList extends StatelessWidget {
  const _SourceList({required this.state});

  final CloudFilePickerState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cubit = context.read<CloudFilePickerCubit>();
    if (state.loadingSources) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final source in state.sources) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 2),
            child: Text(
              source.email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 12, 4),
            child: Text(
              _providerLabel(source.provider),
              style: TextStyle(color: c.textMuted, fontSize: 11),
            ),
          ),
          for (final collection in source.collections)
            _SourceTile(
              icon: _collectionIcon(collection),
              label: _collectionLabel(collection),
              selected: state.accountId == source.accountId &&
                  state.collection == collection &&
                  !state.searching,
              onTap: () => cubit.selectSource(source.accountId, collection),
            ),
        ],
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected ? c.selectionBg : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Icon(icon,
                    size: 17,
                    color: selected ? AppColors.accent : c.textTertiary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: selected ? c.textPrimary : c.textBody,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Phone: the same choices as one dropdown above the list.
class _SourceDropdown extends StatelessWidget {
  const _SourceDropdown({required this.state});

  final CloudFilePickerState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cubit = context.read<CloudFilePickerCubit>();
    final entries = [
      for (final s in state.sources)
        for (final collection in s.collections) (s, collection),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    final current = entries.indexWhere(
        (e) => e.$1.accountId == state.accountId && e.$2 == state.collection);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: DropdownButtonFormField<int>(
        initialValue: current < 0 ? null : current,
        isExpanded: true,
        dropdownColor: c.surfacePanel,
        decoration: InputDecoration(
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
        items: [
          for (var i = 0; i < entries.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(
                '${entries[i].$1.email} · ${_collectionLabel(entries[i].$2)}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.textPrimary, fontSize: 14),
              ),
            ),
        ],
        onChanged: (i) {
          if (i != null) cubit.selectSource(entries[i].$1.accountId, entries[i].$2);
        },
      ),
    );
  }
}

class _FileArea extends StatelessWidget {
  const _FileArea({required this.purpose, required this.onConfirm});

  final CloudFilePickerPurpose purpose;
  final void Function(List<CloudFile>) onConfirm;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cubit = context.read<CloudFilePickerCubit>();
    final state = context.watch<CloudFilePickerCubit>().state;

    if (state.loadingSources) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (state.sources.isEmpty) {
      return _Message(
        icon: Icons.cloud_off_outlined,
        text: 'None of your accounts has cloud files. Add a Microsoft 365, '
            'Google or NightMail Server account to attach from its drive.',
      );
    }
    final source = state.source;
    if (source != null && !source.hasReadAccess) {
      return _Message(
        icon: Icons.lock_outline,
        text: 'To browse its files here, ${source.email} needs to grant '
            'NightMail read-only access to them. You will be asked to sign in '
            'once.',
        error: state.error,
        action: state.granting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : FilledButton(
                onPressed: cubit.grantAccess,
                child: const Text('Grant access'),
              ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Breadcrumb(state: state),
        Divider(height: 1, color: c.separator),
        Expanded(child: _buildList(context, state, cubit)),
      ],
    );
  }

  Widget _buildList(BuildContext context, CloudFilePickerState state,
      CloudFilePickerCubit cubit) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (state.error != null) {
      return _Message(
        icon: Icons.error_outline,
        text: state.error!,
        action: TextButton(onPressed: cubit.retry, child: const Text('Retry')),
      );
    }
    if (state.items.isEmpty) {
      return _Message(
        icon: Icons.folder_open_outlined,
        text: state.searching ? 'No files match "${state.query}"' : 'This folder is empty',
      );
    }
    return ListView.builder(
      itemCount: state.items.length,
      itemBuilder: (context, i) {
        final file = state.items[i];
        return _FileRow(
          file: file,
          selected: state.selected.contains(file),
          onTap: () =>
              file.isFolder ? cubit.openFolder(file) : cubit.toggle(file),
          onDoubleTap: file.isFolder
              ? null
              : () {
                  final selected = state.selected.contains(file)
                      ? state.selected
                      : [...state.selected, file];
                  onConfirm(selected);
                },
        );
      },
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.state});

  final CloudFilePickerState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cubit = context.read<CloudFilePickerCubit>();
    final crumbs = <Widget>[];
    void add(String label, VoidCallback? onTap) {
      if (crumbs.isNotEmpty) {
        crumbs.add(Icon(Icons.chevron_right, size: 16, color: c.textMuted));
      }
      crumbs.add(InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            label,
            style: TextStyle(
              color: onTap == null ? c.textPrimary : c.textTertiary,
              fontSize: 13,
              fontWeight: onTap == null ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ));
    }

    if (state.searching) {
      add('Search results for "${state.query}"', null);
    } else {
      add(_collectionLabel(state.collection),
          state.path.isEmpty ? null : () => cubit.goTo(0));
      for (var i = 0; i < state.path.length; i++) {
        final last = i == state.path.length - 1;
        add(state.path[i].name, last ? null : () => cubit.goTo(i + 1));
      }
    }
    return SizedBox(
      height: 36,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: crumbs),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.selected,
    required this.onTap,
    this.onDoubleTap,
  });

  final CloudFile file;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  static final _date = DateFormat.yMMMd();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final details = [
      if (file.modified != null) _date.format(file.modified!.toLocal()),
      if (!file.isFolder && file.size != null) _formatSize(file.size!),
    ].join(' · ');
    return Material(
      color: selected ? c.selectionBg : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              if (file.isFolder)
                const SizedBox(width: 24)
              else
                SizedBox(
                  width: 24,
                  child: Icon(
                    selected ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 18,
                    color: selected ? AppColors.accent : c.textMuted,
                  ),
                ),
              const SizedBox(width: 8),
              Icon(_iconFor(file), size: 20, color: c.textTertiary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textPrimary, fontSize: 13),
                    ),
                    if (details.isNotEmpty)
                      Text(details,
                          style: TextStyle(color: c.textMuted, fontSize: 11)),
                  ],
                ),
              ),
              if (file.isFolder)
                Icon(Icons.chevron_right, size: 18, color: c.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(CloudFile file) {
    if (file.isFolder) return Icons.folder;
    final type = file.mimeType ?? '';
    final name = file.name.toLowerCase();
    if (type.contains('spreadsheet') || name.endsWith('.xlsx') ||
        name.endsWith('.csv')) {
      return Icons.table_chart_outlined;
    }
    if (type.contains('presentation') || name.endsWith('.pptx')) {
      return Icons.slideshow_outlined;
    }
    if (type.startsWith('image/')) return Icons.image_outlined;
    if (type == 'application/pdf' || name.endsWith('.pdf')) {
      return Icons.picture_as_pdf_outlined;
    }
    if (type.contains('document') || type.startsWith('text/')) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.action,
    this.error,
  });

  final IconData icon;
  final String text;
  final Widget? action;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 32, color: c.textMuted),
              const SizedBox(height: 12),
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.textBody, fontSize: 13)),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.errorBannerText, fontSize: 12)),
              ],
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.purpose,
    required this.selected,
    required this.onClear,
    required this.onConfirm,
  });

  final CloudFilePickerPurpose purpose;
  final List<CloudFile> selected;
  final VoidCallback? onClear;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = selected.length;
    final verb = purpose == CloudFilePickerPurpose.attach ? 'Attach' : 'Insert link';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              n == 0
                  ? 'Select one or more files'
                  : n == 1
                      ? selected.single.name
                      : '$n files selected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.textTertiary, fontSize: 12),
            ),
          ),
          if (onClear != null)
            TextButton(onPressed: onClear, child: const Text('Clear')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: n == 0 ? null : onConfirm,
            child: Text(n > 1 && purpose == CloudFilePickerPurpose.link
                ? 'Insert links'
                : verb),
          ),
        ],
      ),
    );
  }
}
