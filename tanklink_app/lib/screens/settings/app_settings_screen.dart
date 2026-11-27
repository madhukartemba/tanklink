import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../util/app_prefs.dart';
import '../../util/haptics.dart';
import 'update_tiles.dart';

void openAppSettings(BuildContext context) {
  Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const AppSettingsScreen()));
}

/// Settings kept on this phone, not on the pump.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPrefs>();
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('This phone')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const AppUpdateTile(),
          Text('Appearance', style: text.titleSmall),
          const SizedBox(height: 10),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto_rounded),
                label: Text('Phone'),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_rounded),
                label: Text('Light'),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_rounded),
                label: Text('Dark'),
              ),
            ],
            selected: {prefs.theme},
            showSelectedIcon: false,
            onSelectionChanged: Haptics.pick((s) => prefs.setTheme(s.first)),
          ),
          const SizedBox(height: 6),
          Text(
            'Phone follows your phone’s dark mode.',
            style: text.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.vibration_rounded),
            title: const Text('Vibration'),
            subtitle: const Text(
              'Feel the pump start and stop, the slider and switches',
            ),
            value: prefs.haptics,
            onChanged: (on) async {
              await prefs.setHaptics(on);
              Haptics.play(Haptic.toggleOn);
            },
          ),
        ],
      ),
    );
  }
}
