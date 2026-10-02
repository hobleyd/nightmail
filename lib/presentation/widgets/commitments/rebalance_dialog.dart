import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/workload_forecast.dart';

/// The revised schedule "Future Me" proposes for an overloaded day: each
/// move as a row the user can leave in or take out, then Apply.
///
/// [onApply] performs the chosen moves and answers how many the calendar
/// accepted; the dialog closes with that count.
class RebalanceDialog extends StatefulWidget {
  const RebalanceDialog({
    super.key,
    required this.plan,
    required this.onApply,
  });

  final RebalancePlan plan;
  final Future<int> Function(List<ScheduleMove> moves) onApply;

  static Future<int> show(
    BuildContext context, {
    required RebalancePlan plan,
    required Future<int> Function(List<ScheduleMove> moves) onApply,
  }) async {
    final result = await showDialog<int>(
      context: context,
      builder: (_) => RebalanceDialog(plan: plan, onApply: onApply),
    );
    return result ?? 0;
  }

  @override
  State<RebalanceDialog> createState() => _RebalanceDialogState();
}

class _RebalanceDialogState extends State<RebalanceDialog> {
  late final Set<ScheduleMove> _selected = {...widget.plan.moves};
  bool _applying = false;

  int get _relieved =>
      _selected.fold(0, (sum, m) => sum + m.length.inMinutes);

  int get _remainingOver =>
      widget.plan.day.demandMinutes - _relieved - widget.plan.day.capacityMinutes;

  Future<void> _apply() async {
    setState(() => _applying = true);
    final moves = [
      for (final m in widget.plan.moves)
        if (_selected.contains(m)) m,
    ];
    final applied = await widget.onApply(moves);
    if (!mounted) return;
    Navigator.of(context).pop(applied);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final day = widget.plan.day;
    final dayName = DateFormat('EEEE d MMMM').format(day.day);
    return Dialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Lighten ${DateFormat('EEEE').format(day.day)}',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$dayName has ${_hours(day.demandMinutes)} to do and '
                '${_hours(day.capacityMinutes)} free after meetings. These '
                'moves would take the pressure off:',
                style: TextStyle(color: c.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: c.separatorStrong),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: widget.plan.moves.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: c.separator),
                    itemBuilder: (context, i) {
                      final m = widget.plan.moves[i];
                      return _MoveRow(
                        move: m,
                        selected: _selected.contains(m),
                        onChanged: (v) => setState(() {
                          if (v) {
                            _selected.add(m);
                          } else {
                            _selected.remove(m);
                          }
                        }),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _selected.isEmpty
                    ? 'Nothing selected.'
                    : _remainingOver <= 0
                        ? 'Relieves ${_hours(_relieved)} and brings the day '
                            'within capacity.'
                        : 'Relieves ${_hours(_relieved)}; the day is still '
                            'over by ${_hours(_remainingOver)}.',
                style: TextStyle(
                  color: _remainingOver <= 0 && _selected.isNotEmpty
                      ? c.textSecondary
                      : AppColors.notification,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _applying ? null : () => Navigator.of(context).pop(0),
                    style: TextButton.styleFrom(foregroundColor: c.textMuted),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _applying || _selected.isEmpty ? null : _apply,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      _applying
                          ? 'Applying…'
                          : 'Apply ${_selected.length} '
                              '${_selected.length == 1 ? 'move' : 'moves'}',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoveRow extends StatelessWidget {
  const _MoveRow({
    required this.move,
    required this.selected,
    required this.onChanged,
  });

  final ScheduleMove move;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final what = move.commitment.subject.trim().isEmpty
        ? move.commitment.snippet
        : move.commitment.subject;
    final from = move.from;
    final fmt = DateFormat('EEE').add_jm();
    return InkWell(
      onTap: () => onChanged(!selected),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 6),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: AppColors.accent,
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$what · ${move.commitment.counterpart.displayName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    from == null
                        ? 'New block · ${fmt.format(move.toStart)} '
                            '(${_minutes(move.length)})'
                        : '${fmt.format(from)} → ${fmt.format(move.toStart)} '
                            '(${_minutes(move.length)})',
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _hours(int minutes) {
  if (minutes <= 0) return '0 h';
  final h = minutes / 60;
  return h == h.roundToDouble() ? '${h.round()} h' : '${h.toStringAsFixed(1)} h';
}

String _minutes(Duration d) =>
    d.inMinutes < 60 ? '${d.inMinutes} min' : _hours(d.inMinutes);
