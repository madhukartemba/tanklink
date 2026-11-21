import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alert_bridge.dart';

const _askedKey = 'alerts_prompted';

/// Once, the first time the home screen shows a pump: say why TankLink wants
/// to send notifications, then ask Android. Alerts are on by default, so this
/// is what lets them show. Declining is fine: Settings > Alerts says what is
/// missing and opens the right Android screen.
Future<void> askForAlertsOnce(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_askedKey) ?? false) return;
  if (!await AlertBridge.isSupported()) return;
  final perms = await AlertBridge.permissions();
  if (perms.notifications && perms.scan) {
    await prefs.setBool(_askedKey, true);
    return;
  }
  if (!context.mounted) return;
  final allow = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      icon: const Icon(Icons.notifications_active_outlined, size: 32),
      title: const Text('Get alerts from your pump'),
      content: const Text(
        'TankLink can tell you when the tank is full, the pump stops, the '
        'power is cut or a tank sensor battery is low, even when the app is '
        'closed.\n\n'
        'To do that, Android needs your permission to show notifications, and '
        'to look for the pump nearby over Bluetooth.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  await prefs.setBool(_askedKey, true);
  if (allow == true) await AlertBridge.requestPermissions();
}
