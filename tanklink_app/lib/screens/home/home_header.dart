import 'package:material_ui/material_ui.dart';

import '../../ble/pump_session.dart';
import '../add_pump_screen.dart';

class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.onPumps, required this.onAdd});

  final VoidCallback onPumps;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'TankLink',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
        ),
        const Spacer(),
        IconButton.filledTonal(
          tooltip: 'Pumps',
          onPressed: onPumps,
          icon: const Icon(Icons.list_alt_rounded),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          tooltip: 'Add pump',
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded),
        ),
      ],
    );
  }
}

class PumpHeader extends StatelessWidget {
  const PumpHeader({
    super.key,
    required this.pump,
    required this.connecting,
    required this.connected,
    required this.status,
    required this.onOpenList,
    required this.onSettings,
    required this.onRename,
  });

  final SavedPump pump;
  final bool connecting;
  final bool connected;
  final String status;
  final VoidCallback onOpenList;
  final VoidCallback onSettings;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onOpenList,
        onLongPress: onRename,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: connected
                      ? const Color(0xFF3DDC97)
                      : connecting
                      ? scheme.tertiary
                      : scheme.outline,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pump.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      connected
                          ? 'Online · #${pump.serial}'
                          : connecting
                          ? status
                          : 'Offline · #${pump.serial}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: onSettings,
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TankChips extends StatelessWidget {
  const TankChips({super.key, required this.session});

  final PumpSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final slots = session.tanks;
    if (slots.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final slot in slots)
          _TankChip(session: session, slot: slot, scheme: scheme),
      ],
    );
  }
}

class _TankChip extends StatelessWidget {
  const _TankChip({
    required this.session,
    required this.slot,
    required this.scheme,
  });

  final PumpSession session;
  final TankSlot slot;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final selected = slot.index == session.activeSlot;
    final locked = session.pumpOn && !selected;
    final offline = !session.tankOnline;
    final full = session.slotIsFull(slot);
    final label = offline
        ? 'Offline'
        : full
        ? 'Full'
        : 'Not full';
    return FilterChip(
      selected: selected,
      showCheckmark: false,
      label: Text(
        '${slot.name.isEmpty ? session.tankNameFor(slot.index) : slot.name} · $label',
      ),
      onSelected: locked
          ? null
          : (_) async {
              if (selected) return;
              try {
                await session.selectTank(slot.index);
              } catch (e) {
                if (!context.mounted) return;
                final msg = e.toString().replaceFirst('StateError: ', '');
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(msg)));
              }
            },
      selectedColor: full && !offline
          ? const Color(0xFF1FA97A).withValues(alpha: 0.22)
          : scheme.secondaryContainer,
      side: BorderSide(
        color: locked
            ? scheme.outlineVariant
            : selected
            ? scheme.primary
            : scheme.outlineVariant,
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.water_drop_outlined, size: 56, color: scheme.primary),
        const SizedBox(height: 16),
        Text(
          'No pumps yet',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Hold the pump button for 5 seconds to enter pairing, then add it here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AddPumpScreen()),
            );
          },
          icon: const Icon(Icons.add),
          label: const Text('Add pump'),
        ),
      ],
    );
  }
}
