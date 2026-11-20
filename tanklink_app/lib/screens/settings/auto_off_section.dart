import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../ble/pump_session.dart';
import '../../ble/tanklink_uuids.dart';
import '../../util/format.dart';

/// Auto-off switch and duration for one tank. With several tanks a selector
/// picks which tank is being edited; each tank keeps its own limit.
class AutoOffSection extends StatefulWidget {
  const AutoOffSection({super.key, required this.ready});

  final bool ready;

  @override
  State<AutoOffSection> createState() => _AutoOffSectionState();
}

class _AutoOffSectionState extends State<AutoOffSection> {
  static const int _minMinutes = 1;
  static const int _maxMinutes = TankLinkUuids.autoOffMaxMin;

  int _draftMinutes = 30;

  /// Auto-off can't be turned off: it is the last stop if a float or the
  /// radio fails. The pump clamps to 1–240 minutes.
  static const bool _autoEnabled = true;

  /// The tank whose auto-off is being edited; null until the tank list loads.
  int? _editSlot;

  void _hydrateFromSession(PumpSession session) {
    if (session.tanks.isEmpty) return;
    if (_editSlot != null && session.slotAt(_editSlot!) != null) return;
    _loadSlot(session, session.activeSlot);
  }

  void _loadSlot(PumpSession session, int slot) {
    final v = session.autoOffMinFor(slot);
    _editSlot = slot;
    _draftMinutes = v > 0 ? v.clamp(_minMinutes, _maxMinutes) : 30;
  }

  Future<void> _commitAuto(int minutes) async {
    if (!mounted || _editSlot == null) return;
    final session = context.read<PumpSession>();
    if (!session.ready) return;
    try {
      await session.setAutoOffMinutes(_editSlot!, minutes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('StateError: ', ''))),
      );
    }
  }

  Future<void> _applyDraft(int minutes) async {
    final m = minutes.clamp(_minMinutes, _maxMinutes);
    setState(() => _draftMinutes = m);
    await _commitAuto(m);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final ready = widget.ready;
    _hydrateFromSession(session);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.timer_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.multiTank ? 'Auto-off per tank' : 'Auto-off',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    !ready
                        ? 'Connect to change'
                        : _editSlot == null
                        ? 'Loading…'
                        : 'Stops after ${formatAutoOff(_draftMinutes)}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (ready && session.multiTank && _editSlot != null) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            // Up to eight tanks: chips wrap where segments would overflow.
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final t in session.tanks)
                  ChoiceChip(
                    label: Text(
                      t.name.isEmpty ? session.tankNameFor(t.index) : t.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: t.index == _editSlot,
                    onSelected: (_) =>
                        setState(() => _loadSlot(session, t.index)),
                  ),
              ],
            ),
          ),
        ],
        if (ready && _editSlot != null)
          _AutoFillRow(session: session, slot: _editSlot!),
        if (ready && _autoEnabled && _editSlot != null) ...[
          const SizedBox(height: 8),
          // Indent to match title text (icon 24 + gap 16).
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton.filledTonal(
                      tooltip: '−1 min',
                      onPressed: () => _applyDraft(_draftMinutes - 1),
                      icon: const Icon(Icons.remove),
                    ),
                    Expanded(
                      child: Text(
                        formatAutoOff(_draftMinutes),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: '+1 min',
                      onPressed: () => _applyDraft(_draftMinutes + 1),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                Slider(
                  min: _minMinutes.toDouble(),
                  max: _maxMinutes.toDouble(),
                  divisions: _maxMinutes - _minMinutes,
                  value: _draftMinutes
                      .clamp(_minMinutes, _maxMinutes)
                      .toDouble(),
                  label: formatAutoOff(_draftMinutes),
                  onChanged: (v) {
                    setState(() => _draftMinutes = v.round());
                  },
                  onChangeEnd: (v) => _commitAuto(v.round()),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '1 min',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        '4 h',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// "Fill when low" for one tank. Only a tank with both floats can use it.
class _AutoFillRow extends StatefulWidget {
  const _AutoFillRow({required this.session, required this.slot});

  final PumpSession session;
  final int slot;

  @override
  State<_AutoFillRow> createState() => _AutoFillRowState();
}

class _AutoFillRowState extends State<_AutoFillRow> {
  bool _busy = false;

  Future<void> _set(bool on) async {
    setState(() => _busy = true);
    try {
      await widget.session.setAutoFill(widget.slot, on);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('StateError: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final scheme = Theme.of(context).colorScheme;
    final slot = session.slotAt(widget.slot);
    final can = session.canAutoFill(widget.slot);
    final on = can && (slot?.autoFill ?? false);
    final String subtitle;
    if (session.pumpProtoMinor < TankLinkUuids.autoFillMinor) {
      subtitle = 'Update the pump to use this';
    } else if (!can) {
      subtitle =
          'Needs an almost-empty float on this tank. Set it in Tank sensors.';
    } else {
      subtitle =
          'Starts when the water drops below the almost-empty float, '
          'stops when the tank is full';
    }
    return Padding(
      padding: const EdgeInsets.only(left: 40, top: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Fill when low',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: on, onChanged: !can || _busy ? null : _set),
        ],
      ),
    );
  }
}
