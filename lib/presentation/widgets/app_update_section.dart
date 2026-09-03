import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:version/version.dart';

import '../../core/theme/app_colors.dart';
import '../../infrastructure/update/app_update_status.dart';
import '../blocs/update/update_cubit.dart';

/// The update block in Settings → About: what state the updater is in, the one
/// button that moves it on, and the newest release's notes.
///
/// **One button, whose meaning follows the phase**, rather than a row of them —
/// there is only ever one sensible next step, and naming it ("Download update",
/// "Restart and install") is clearer than a fixed "Update" that does different
/// things at different times.
///
/// The notes are shown whether or not an update is waiting, because the hosted
/// document always describes the newest published release: with an update
/// pending it is what you are about to get, and without one it is what you
/// already have. The heading says which.
/// Which of the document's releases the panel draws, newest first.
///
/// Everything published since the running build — so a reader who skipped
/// versions sees what changed in each of them, not only in the release they are
/// about to install.
///
/// **When there is nothing newer it falls back to the newest release rather
/// than to nothing.** The hosted document describes the newest published
/// release either way: with an update pending it is what you are about to get,
/// and without one it is what you already have, which is worth showing. An
/// empty list there would take the "What's new" block off the panel for
/// everyone who is up to date.
///
/// The same fallback covers an installed version that will not parse and a
/// release that names no version — neither can be placed against the other, and
/// silently dropping a release is worse than showing one the reader has.
@visibleForTesting
List<UpdateReleaseNotes> releaseNotesToShow(
  List<UpdateReleaseNotes> notes,
  String? installedVersion,
) {
  if (notes.isEmpty) return const [];

  final installed = _parseVersion(installedVersion);
  if (installed == null) return notes.take(1).toList();

  final newer = [
    for (final release in notes)
      if (_parseVersion(release.version) case final version?)
        if (version > installed) release,
  ];

  return newer.isEmpty ? notes.take(1).toList() : newer;
}

/// `1.22.3+157` and `1.22.4` both parse; build metadata does not affect the
/// ordering, which is what lets an installed build be compared with a release.
Version? _parseVersion(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    return Version.parse(value.startsWith('v') ? value.substring(1) : value);
  } on FormatException {
    return null;
  }
}

class AppUpdateSection extends StatelessWidget {
  const AppUpdateSection({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UpdateCubit, AppUpdateStatus>(
      builder: (context, status) {
        final c = context.colors;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Divider(color: c.border, height: 1),
            const SizedBox(height: 20),
            _StatusLine(status: status),
            const SizedBox(height: 12),
            _UpdateAction(status: status),
            if (status.error != null) ...[
              const SizedBox(height: 12),
              _ErrorLine(message: status.error!),
            ],
            for (final release
                in releaseNotesToShow(status.notes, status.installedVersion))
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: _ReleaseNotes(
                  notes: release,
                  isForPendingUpdate: status.hasActionableUpdate ||
                      status.phase == AppUpdatePhase.downloading,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status});

  final AppUpdateStatus status;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    final (text, colour) = switch (status.phase) {
      AppUpdatePhase.unsupported => (
          'Updates for this build are managed outside the app.',
          c.textMuted,
        ),
      AppUpdatePhase.idle => ('', c.textMuted),
      AppUpdatePhase.checking => ('Checking for updates…', c.textMuted),
      AppUpdatePhase.upToDate => ('NightMail is up to date.', c.textMuted),
      AppUpdatePhase.available => (
          'Version ${status.availableVersion ?? 'unknown'} is available.',
          AppColors.accent,
        ),
      AppUpdatePhase.freshInstallRequired => (
          'Version ${status.availableVersion ?? 'unknown'} must be installed '
              'from a fresh download.',
          AppColors.accent,
        ),
      AppUpdatePhase.downloading => (
          _downloadLabel(status),
          c.textSecondary,
        ),
      AppUpdatePhase.readyToInstall => (
          'Version ${status.availableVersion ?? 'unknown'} is ready to install.',
          AppColors.accent,
        ),
      AppUpdatePhase.installing => ('Installing…', c.textSecondary),
      AppUpdatePhase.failed => ('Could not check for updates.', c.textMuted),
    };

    if (text.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: colour, fontSize: 13),
        ),
        if (status.phase == AppUpdatePhase.downloading) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: 220,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: status.progress,
                minHeight: 4,
                backgroundColor: c.surfaceBase,
                valueColor: AlwaysStoppedAnimation(AppColors.accent),
              ),
            ),
          ),
        ],
      ],
    );
  }

  static String _downloadLabel(AppUpdateStatus status) {
    final progress = status.progress;
    if (progress == null) return 'Downloading update…';
    return 'Downloading update… ${(progress * 100).round()}%';
  }
}

class _UpdateAction extends StatelessWidget {
  const _UpdateAction({required this.status});

  final AppUpdateStatus status;

  @override
  Widget build(BuildContext context) {
    if (status.phase == AppUpdatePhase.unsupported) {
      return const SizedBox.shrink();
    }

    final cubit = context.read<UpdateCubit>();

    // A busy phase gets no button at all rather than a disabled one: the status
    // line above already carries a spinner or a progress bar, and a greyed-out
    // button beside it just repeats that nothing can be done yet.
    if (status.isBusy) {
      return status.phase == AppUpdatePhase.checking ||
              status.phase == AppUpdatePhase.installing
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const SizedBox.shrink();
    }

    final (label, icon, onPressed) = switch (status.phase) {
      AppUpdatePhase.available => (
          'Download update',
          Icons.download_rounded,
          cubit.download,
        ),
      AppUpdatePhase.freshInstallRequired => (
          'Open download page',
          Icons.open_in_new_rounded,
          cubit.openFreshInstallDownload,
        ),
      AppUpdatePhase.readyToInstall => (
          'Restart and install',
          Icons.restart_alt_rounded,
          cubit.install,
        ),
      _ => ('Check for updates', Icons.refresh_rounded, cubit.check),
    };

    final isPrimary = status.hasActionableUpdate;
    final c = context.colors;

    return TextButton.icon(
      onPressed: () => onPressed(),
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: TextButton.styleFrom(
        foregroundColor: isPrimary ? Colors.white : c.textSecondary,
        backgroundColor: isPrimary ? AppColors.accent : c.surfaceBase,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      textAlign: TextAlign.center,
      style: const TextStyle(color: AppColors.notification, fontSize: 12),
    );
  }
}

class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes({required this.notes, required this.isForPendingUpdate});

  final UpdateReleaseNotes notes;
  final bool isForPendingUpdate;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final version = notes.version;
    final heading = isForPendingUpdate
        ? "What's new in ${version ?? 'the next release'}"
        : version == null
            ? "What's new"
            : "What's new in $version";

    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (notes.summary != null) ...[
            const SizedBox(height: 8),
            Text(
              notes.summary!,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
          for (final section in notes.sections) ...[
            const SizedBox(height: 16),
            Text(
              section.title,
              style: TextStyle(
                color: c.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 6),
            for (final item in section.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 8),
                      child: Container(
                        width: 3,
                        height: 3,
                        decoration: BoxDecoration(
                          color: c.textMuted,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            if (item.title != null)
                              TextSpan(
                                text: '${item.title}: ',
                                style: TextStyle(
                                  color: c.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            TextSpan(text: item.body),
                          ],
                        ),
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
