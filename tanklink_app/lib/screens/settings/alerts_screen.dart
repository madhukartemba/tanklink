import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../alerts/alert_bridge.dart';
import '../../ble/pump_session.dart';
import '../../ble/tanklink_uuids.dart';

/// Alerts with the app closed: the pump puts an alert in its Bluetooth
/// advertisement and Android wakes the app to show it (docs/plan-alerts.md).
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _supported = false;
  bool _enabled = false;
  bool _notifications = false;
  bool _scan = false;
  bool _batteryOk = false;
  List<int> _types = const [1, 2, 3, 4, 5, 7];
  bool _sending = false;

  static const _typeNames = {
    TankLinkUuids.alertTankFull: 'Tank full',
    TankLinkUuids.alertAutoOff: 'Stopped by auto-off',
    TankLinkUuids.alertPowerCut: 'Fill cut short by a power cut',
    TankLinkUuids.alertTankOffline: 'Tank sensor out of range',
    TankLinkUuids.alertBatteryLow: 'Tank sensor battery low',
    TankLinkUuids.alertSensorRemoved: 'Tank sensor removed',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system permission or battery screens.
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    final supported = await AlertBridge.isSupported();
    final enabled = await AlertBridge.isEnabled();
    final perms = await AlertBridge.permissions();
    final types = await AlertBridge.types();
    final battery = await AlertBridge.batteryUnrestricted();
    if (!mounted) return;
    setState(() {
      _supported = supported;
      _enabled = enabled;
      _notifications = perms.notifications;
      _scan = perms.scan;
      _types = types;
      _batteryOk = battery;
      _loading = false;
    });
  }

  Future<void> _toggle(bool on) async {
    if (on) await AlertBridge.requestPermissions();
    await AlertBridge.setEnabled(on);
    if (mounted) await context.read<PumpSession>().syncAlertBridge();
    await _load();
  }

  Future<void> _toggleType(int type, bool on) async {
    final next = [..._types.where((t) => t != type), if (on) type]..sort();
    await AlertBridge.setTypes(next);
    await _load();
  }

  Future<void> _test(PumpSession session) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      await session.sendTestAlert();
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Sent. You can close the app: a notification should appear within a minute.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    final pump = session.selected;
    final hasKey = pump?.alertKey != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                if (!_supported)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Alerts with the app closed need Android 12 or later.',
                    ),
                  )
                else ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Alerts when the app is closed'),
                    subtitle: const Text(
                      'Works when your phone is near the pump. The pump sends '
                      'each alert over Bluetooth for an hour.',
                    ),
                    value: _enabled,
                    onChanged: _toggle,
                  ),
                  if (_enabled && (!_notifications || !_scan))
                    Card(
                      color: scheme.errorContainer,
                      child: ListTile(
                        leading: const Icon(Icons.warning_amber_rounded),
                        title: Text(
                          !_notifications
                              ? 'Notifications are off for TankLink'
                              : 'Nearby devices permission is off',
                        ),
                        subtitle: const Text('Allow it so alerts can show.'),
                        trailing: TextButton(
                          onPressed: AlertBridge.openNotificationSettings,
                          child: const Text('Open'),
                        ),
                      ),
                    ),
                  if (!hasKey)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        session.ready ? 'Getting this pump ready for alerts…' : 'Connect to the pump once so it can set up alerts.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  const Divider(height: 24),
                  Text(
                    'Tell me about',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  for (final e in _typeNames.entries)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(e.value),
                      value: _types.contains(e.key),
                      onChanged: _enabled ? (v) => _toggleType(e.key, v) : null,
                    ),
                  const Divider(height: 24),
                  FilledButton.tonalIcon(
                    onPressed: session.ready && !_sending && _enabled && hasKey
                        ? () => _test(session)
                        : null,
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: const Text('Send a test alert'),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _batteryOk
                          ? Icons.battery_charging_full_rounded
                          : Icons.battery_alert_rounded,
                    ),
                    title: Text(
                      _batteryOk
                          ? 'Battery use is unrestricted'
                          : 'Let TankLink run in the background',
                    ),
                    subtitle: const Text(
                      'Some phones (Xiaomi, Oppo, Vivo, OnePlus, Huawei) stop '
                      'background apps. Allow autostart and set battery to '
                      '"No restrictions" for TankLink.',
                    ),
                    trailing: TextButton(
                      onPressed: AlertBridge.openBatterySettings,
                      child: const Text('Open'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'If you force-stop the app, alerts stop until you open it again.',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
