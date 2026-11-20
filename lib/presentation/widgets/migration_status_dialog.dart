import 'package:flutter/material.dart';
import 'adaptive_alert_dialog.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/datasources/local/migration_local_datasource.dart';
import '../../infrastructure/migration/account_migration_service.dart';
import '../../infrastructure/migration/mail_rule_migrator.dart';
import '../blocs/migration/migration_cubit.dart';
import '../blocs/migration/migration_state.dart';

/// Shows a running/paused/completed/failed account migration's status and,
/// per the feature's "any errors should be retried but if they fail again
/// reported on" requirement, the list of messages that were retried and
/// still failed. The migration itself keeps running in the background if
/// this dialog is closed — [MigrationCubit] is a lazy singleton, not scoped
/// to this dialog's lifetime.
class MigrationStatusDialog extends StatelessWidget {
  const MigrationStatusDialog({
    super.key,
    required this.sourceAccountLabel,
    required this.targetAccountLabel,
    this.scope = MigrationScope.account,
  });

  final String sourceAccountLabel;
  final String targetAccountLabel;
  final MigrationScope scope;

  @override
  Widget build(BuildContext context) {
    return AdaptiveAlertDialog(
      title: Text(switch (scope) {
        MigrationScope.account =>
          'Migrating $sourceAccountLabel → $targetAccountLabel',
        MigrationScope.inbox =>
          'Migrating Inbox: $sourceAccountLabel → $targetAccountLabel',
      }),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BlocBuilder<MigrationCubit, MigrationState>(
              builder: (context, state) {
                final job = state.job;
                if (job == null) {
                  return const SizedBox(
                    height: 80,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _StatusIcon(
                            status: job.status,
                            hasFailures: state.failures.isNotEmpty),
                        const SizedBox(width: 8),
                        Text(
                            _statusLabel(job.status,
                                hasFailures: state.failures.isNotEmpty),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    if (job.status == MigrationJobStatus.running &&
                        state.progress != null) ...[
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(left: 24),
                        child: Text(
                          _progressLabel(state.progress!),
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey),
                        ),
                      ),
                    ],
                    if (job.status == MigrationJobStatus.paused) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'This migration is stalled — one of the two '
                        'accounts needs to be signed in again before it can '
                        'continue. Switch to it in the account menu (marked '
                        'with a red icon) to sign in, then reopen this '
                        'dialog to pick up where it left off.',
                        style: TextStyle(fontSize: 12),
                      ),
                      if (job.lastError != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          job.lastError!,
                          style: const TextStyle(
                              color: Colors.redAccent, fontSize: 11),
                        ),
                      ],
                    ] else if (job.lastError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        job.lastError!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (state.failures.isEmpty)
                      const Text(
                        'No permanently failed messages.',
                        style: TextStyle(fontSize: 12),
                      )
                    else ...[
                      Text(
                        '${state.failures.length} message(s) could not be '
                        'copied after retrying:',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: state.failures.length,
                          itemBuilder: (context, i) {
                            final failure = state.failures[i];
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                failure.lastError ?? 'Unknown error',
                                style: const TextStyle(fontSize: 12),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _RulesSection(
                      state: state,
                      sourceAccountLabel: sourceAccountLabel,
                      targetAccountLabel: targetAccountLabel,
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 8),
            // Shown regardless of job status, not just while running: the
            // migration lives in a singleton service independent of this
            // dialog's lifetime either way, so this stays true whether it's
            // still copying, paused for re-auth, or already finished.
            Text(
              switch (scope) {
                MigrationScope.account =>
                  'This dialog is safe to close — the migration keeps running '
                      'in the background. Reopen it from the account menu.',
                MigrationScope.inbox =>
                  'This dialog is safe to close — the migration keeps running '
                      "in the background. Reopen it from the Inbox's "
                      'right-click menu.',
              },
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  // A job whose every message was at least attempted is 'completed' at the
  // job-status level regardless of outcome — that's what lets it stop
  // polling. But drawing that as a plain green checkmark would misreport
  // "if they fail again, reported on": the headline itself has to say some
  // messages didn't make it, not just the list underneath.
  String _statusLabel(MigrationJobStatus status, {required bool hasFailures}) =>
      switch (status) {
        MigrationJobStatus.running => 'Migrating…',
        MigrationJobStatus.completed => hasFailures
            ? 'Finished — some messages could not be copied'
            : 'Migration complete',
        MigrationJobStatus.paused => 'Paused — needs re-authentication',
        MigrationJobStatus.failed => 'Migration failed',
      };

  // totalCount is left off entirely rather than shown as "N of 0" when the
  // provider didn't supply one (see MigrationProgress.totalCount).
  String _progressLabel(MigrationProgress progress) {
    final total = progress.totalCount;
    return total == null
        ? '${progress.folderName} — ${progress.processedCount} processed'
        : '${progress.folderName} — ${progress.processedCount} of $total';
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.hasFailures});

  final MigrationJobStatus status;
  final bool hasFailures;

  @override
  Widget build(BuildContext context) => switch (status) {
        MigrationJobStatus.running => const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        MigrationJobStatus.completed => hasFailures
            ? const Icon(Icons.warning_amber_rounded,
                color: Colors.orange, size: 18)
            : const Icon(Icons.check_circle, color: Colors.green, size: 18),
        MigrationJobStatus.paused => const Icon(Icons.pause_circle_outline,
            color: Colors.orange, size: 18),
        MigrationJobStatus.failed =>
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
      };
}

/// What became of the source's mail rules: copied once the mail is across,
/// strictly — a rule the new server cannot say exactly is listed with why.
class _RulesSection extends StatelessWidget {
  const _RulesSection({
    required this.state,
    required this.sourceAccountLabel,
    required this.targetAccountLabel,
  });

  final MigrationState state;
  final String sourceAccountLabel;
  final String targetAccountLabel;

  static const _small = TextStyle(fontSize: 12);
  static const _heading = TextStyle(fontWeight: FontWeight.w600, fontSize: 13);

  @override
  Widget build(BuildContext context) {
    final result = state.ruleResult;
    final running = state.job?.status == MigrationJobStatus.running;
    final cubit = context.read<MigrationCubit>();
    final children = <Widget>[];

    if (running && state.targetRunsLocalRules) {
      children.add(Text(
        'Rules on $targetAccountLabel are paused until this migration '
        'finishes, so they do not act on the copied mail.',
        style: _small,
      ));
      children.add(const SizedBox(height: 6));
    }

    if (state.copyingRules) {
      children.add(const Text('Copying rules…', style: _small));
    } else if (result == null) {
      children.add(const Text(
        'Rules are copied once the mail is across.',
        style: _small,
      ));
    } else {
      switch (result.status) {
        case RuleMigrationStatus.nothingToCopy:
          children.add(const Text('No rules to copy.', style: _small));
        case RuleMigrationStatus.needsPermission:
          children.addAll([
            Text(
              'Rules not copied yet: $targetAccountLabel needs one extra '
              'permission to change its rules.',
              style: _small,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => cubit.copyRules(requestPermission: true),
                child: const Text('Sign in to allow it, then copy rules'),
              ),
            ),
          ]);
        case RuleMigrationStatus.failed:
          children.addAll([
            Text(
              'Rules not copied: ${result.message ?? 'unknown error'}',
              style: const TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: cubit.copyRules,
                child: const Text('Try again'),
              ),
            ),
          ]);
        case RuleMigrationStatus.done:
          final parts = [
            '${result.copied} copied',
            if (result.alreadyThere > 0) '${result.alreadyThere} already there',
            if (result.skipped.isNotEmpty)
              '${result.skipped.length} not copied',
          ];
          children.add(Text('Rules: ${parts.join(', ')}.', style: _heading));
          if (result.skipped.isNotEmpty) {
            children.add(const SizedBox(height: 4));
            children.add(ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in result.skipped)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('${s.name} — ${s.reason}', style: _small),
                    ),
                ],
              ),
            ));
          }
          children.addAll(_sourceRules(result, cubit));
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// The question about the old account's copies of the migrated rules,
  /// asked once and remembered: while mail still reaches both accounts,
  /// both sets act on it.
  List<Widget> _sourceRules(RuleMigrationResult result, MigrationCubit cubit) {
    final count = result.migratedSourceRuleIds.length;
    final rules = count == 1 ? 'rule' : 'rules';
    switch (result.sourceRules) {
      case SourceRulesDecision.turnedOff:
        return [
          const SizedBox(height: 6),
          Text('The migrated $rules on $sourceAccountLabel are turned off.',
              style: _small),
        ];
      case SourceRulesDecision.keptRunning:
        return [
          const SizedBox(height: 6),
          Text(
            'The migrated $rules on $sourceAccountLabel are still running — '
            'turn them off in Settings → Rules when you are ready.',
            style: _small,
          ),
        ];
      case SourceRulesDecision.undecided:
        if (count == 0) return const [];
    }
    if (!result.sourceCanDisable) {
      return [
        const SizedBox(height: 6),
        Text(
          '$sourceAccountLabel still has its copies of these filters, and '
          'Gmail filters cannot be switched off. Delete them in Settings → '
          'Rules once mail no longer arrives there.',
          style: _small,
        ),
      ];
    }
    final needsSignIn =
        result.sourceRulesMessage == MailRuleMigrator.needsPermissionMessage;
    final failure = needsSignIn ? null : result.sourceRulesMessage;
    return [
      const SizedBox(height: 8),
      Text(
        'Turn off the $count migrated $rules on $sourceAccountLabel? While '
        'mail still reaches both accounts, both sets of rules act on it — a '
        'forward would go out twice.',
        style: _small,
      ),
      if (needsSignIn)
        Text(
          '$sourceAccountLabel needs one extra permission to change its '
          'rules; you will be asked to sign in.',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      if (failure != null)
        Text(failure,
            style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => cubit.decideSourceRules(turnOff: false),
            child: const Text('Keep running'),
          ),
          TextButton(
            onPressed: () => cubit.decideSourceRules(
              turnOff: true,
              requestPermission: needsSignIn,
            ),
            child: Text(needsSignIn ? 'Sign in and turn off' : 'Turn off'),
          ),
        ],
      ),
    ];
  }
}
