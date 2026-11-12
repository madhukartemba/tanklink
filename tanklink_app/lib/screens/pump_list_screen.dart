import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import 'add_pump_screen.dart';
import 'pump_settings_sheet.dart';

class PumpListScreen extends StatelessWidget {
  const PumpListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Your pumps'),
        actions: [
          IconButton(
            tooltip: 'Add pump',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AddPumpScreen()),
              );
            },
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: session.pumps.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.water_drop_outlined,
                        size: 48, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    const Text('No pumps yet'),
                    const SizedBox(height: 8),
                    Text(
                      'Put the C3 in pairing mode (hold Start+Stop 5s), then add it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AddPumpScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('Add pump'),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: session.pumps.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final p = session.pumps[i];
                final selected = p.remoteId == session.selectedRemoteId;
                return Material(
                  color: selected
                      ? scheme.primaryContainer.withValues(alpha: 0.45)
                      : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(16),
                  child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    leading: CircleAvatar(
                      backgroundColor: selected
                          ? scheme.primary
                          : scheme.surfaceContainerHigh,
                      child: Icon(
                        Icons.water_drop,
                        color: selected
                            ? scheme.onPrimary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    title: Text(
                      p.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text('#${p.serial}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Rename',
                          onPressed: () => showRenamePumpDialog(context, p),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        if (selected)
                          Icon(Icons.check_circle, color: scheme.primary)
                        else
                          IconButton(
                            tooltip: 'Remove',
                            onPressed: () => _confirmForget(context, p),
                            icon: const Icon(Icons.delete_outline),
                          ),
                      ],
                    ),
                    onTap: () async {
                      await session.selectPump(p);
                      if (context.mounted) Navigator.pop(context);
                    },
                    onLongPress: () => showRenamePumpDialog(context, p),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _confirmForget(BuildContext context, SavedPump pump) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${pump.name}?'),
        content: Text(
          'Removes #${pump.serial} from this phone only. '
          'Hold Start and Stop together 5 seconds to open pairing if you want to add it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<PumpSession>().forgetPump(pump);
    }
  }
}
