import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../ble/pump_session.dart';
import '../../link/pump_link.dart';
import '../../update/firmware_update_flow.dart' show showFirmwareConfirmSheet;

String _why(Object e) => e.toString().replaceFirst('Bad state: ', '');

/// Wi-Fi for the pump: status, picking a network, forgetting it, how the
/// phone connects and whether the pump installs its own updates. Works over
/// Bluetooth, and over Wi-Fi once connected.
class WifiScreen extends StatelessWidget {
  const WifiScreen({super.key});

  static String stateText(WifiStatus? w) {
    if (w == null) return 'Not available';
    return switch (w.state) {
      WifiState.off => 'Not set up',
      WifiState.connecting => 'Connecting to ${w.ssid}…',
      WifiState.connected => 'Connected to ${w.ssid}',
      WifiState.wrongPassword => 'Wrong password for ${w.ssid}',
      WifiState.notFound => 'Can’t find ${w.ssid}',
    };
  }

  static String signalText(int rssi) {
    if (rssi >= -55) return 'Strong';
    if (rssi >= -70) return 'Good';
    if (rssi >= -80) return 'Fair';
    return 'Weak';
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final w = session.wifiStatus;
    final pump = session.selected;
    final scheme = Theme.of(context).colorScheme;
    final ready = session.ready && !session.pumpUpdating;
    final hasNetwork = w != null && w.state != WifiState.off;
    final connected = w?.state == WifiState.connected;

    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              connected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
              color: connected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            title: Text(
              session.pumpUpdating
                  ? 'The pump is updating. Wi-Fi changes are paused.'
                  : ready
                  ? stateText(w)
                  : 'Connect to the pump first',
            ),
            subtitle: connected
                ? Text(
                    '${signalText(w!.rssi ?? -100)} signal'
                    '${w.ip != null ? ' · ${w.ip}' : ''}',
                  )
                : null,
          ),
          if (ready && w != null) ...[
            const SizedBox(height: 4),
            FilledButton.tonal(
              onPressed: () => _setUp(context),
              child: Text(hasNetwork ? 'Change network' : 'Set up Wi-Fi'),
            ),
            if (hasNetwork)
              TextButton(
                onPressed: () => _forget(context),
                child: const Text('Forget Wi-Fi'),
              ),
          ],
          const SizedBox(height: 8),
          Text(
            '2.4 GHz networks only. Wi-Fi is optional: Bluetooth keeps working.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const Divider(height: 32),
          if (pump != null) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                session.link == LinkKind.wifi
                    ? Icons.wifi_rounded
                    : Icons.bluetooth_rounded,
              ),
              title: const Text('Use Wi-Fi when possible'),
              subtitle: Text(
                pump.bleOnly
                    ? 'Off: the app always uses Bluetooth, even at home.'
                    : 'On: at home the app talks to the pump over Wi-Fi. '
                          'Away from home, or if Wi-Fi fails, it uses Bluetooth.',
              ),
              trailing: Switch(
                value: !pump.bleOnly,
                onChanged: (auto) => session.setBleOnly(!auto),
              ),
            ),
            if (session.connected)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'Connected over '
                  '${session.link == LinkKind.wifi ? 'Wi-Fi' : 'Bluetooth'} '
                  'right now.',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
          const Divider(height: 32),
          _PumpUpdates(session: session, connected: connected),
        ],
      ),
    );
  }

  Future<void> _setUp(BuildContext context) async {
    final session = context.read<PumpSession>();
    final messenger = ScaffoldMessenger.of(context);
    final picked = await showModalBottomSheet<WifiNetwork>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => const _NetworkPicker(),
    );
    if (picked == null || !context.mounted) return;
    final password = picked.secured
        ? await _askPassword(context, picked.ssid)
        : '';
    if (password == null) return;
    try {
      await session.wifiSet(picked.ssid, password);
      messenger.showSnackBar(
        SnackBar(content: Text('Connecting to ${picked.ssid}…')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_why(e))));
    }
  }

  Future<String?> _askPassword(BuildContext context, String ssid) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        var hidden = true;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: Text(ssid),
            content: TextField(
              controller: controller,
              autofocus: true,
              obscureText: hidden,
              maxLength: 63,
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: IconButton(
                  icon: Icon(
                    hidden
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                  onPressed: () => setState(() => hidden = !hidden),
                ),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, controller.text),
                child: const Text('Connect'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _forget(BuildContext context) async {
    final session = context.read<PumpSession>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget Wi-Fi?'),
        content: const Text(
          'The pump leaves the network. You can still use it over Bluetooth.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await session.wifiForget();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_why(e))));
    }
  }
}

/// "just now", "12 min ago", "3 h ago", "2 days ago".
String _ago(int minutes) {
  if (minutes < 1) return 'just now';
  if (minutes < 60) return '$minutes min ago';
  if (minutes < 60 * 24) return '${minutes ~/ 60} h ago';
  return '${minutes ~/ (60 * 24)} days ago';
}

/// The pump's own update check, and the automatic-install option.
class _PumpUpdates extends StatelessWidget {
  const _PumpUpdates({required this.session, required this.connected});

  final PumpSession session;
  final bool connected;

  /// One line for the Pump updates row: what it found, and when it last looked.
  String _status(WifiStatus w) {
    final when = w.lastCheckAgeMin == null
        ? ''
        : ' · checked ${_ago(w.lastCheckAgeMin!)}';
    return switch (w.check) {
      PumpCheckResult.ok when w.update == PumpUpdateState.available =>
        'Version ${w.availableVersion} is ready$when',
      PumpCheckResult.ok => 'Up to date$when',
      PumpCheckResult.noInternet => 'The pump can’t reach the internet',
      PumpCheckResult.error => 'The last check failed. It will try again soon.',
      PumpCheckResult.never => 'Not checked yet',
    };
  }

  Future<void> _check(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    String text;
    try {
      final result = await session.pumpCheckUpdate();
      final w = session.wifiStatus;
      text = switch (result) {
        PumpCheckResult.ok when w?.update == PumpUpdateState.available =>
          'Version ${w!.availableVersion} is available.',
        PumpCheckResult.ok => 'The pump is up to date.',
        PumpCheckResult.noInternet => 'The pump can’t reach the internet.',
        _ => 'The check failed. The pump will try again soon.',
      };
    } catch (e) {
      text = _why(e);
    }
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final w = session.wifiStatus;
    final scheme = Theme.of(context).colorScheme;
    final checking = w?.update == PumpUpdateState.checking;
    final available =
        w?.update == PumpUpdateState.available && !session.pumpUpdating;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (w?.overnightVersion != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.system_update_alt_rounded),
              title: Text(
                'Pump updated to ${w!.overnightVersion} automatically',
              ),
              trailing: TextButton(
                onPressed: session.dismissOvernightUpdate,
                child: const Text('OK'),
              ),
            ),
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cloud_download_outlined),
          title: const Text('Pump updates'),
          subtitle: Text(
            connected && w != null ? _status(w) : 'Needs the pump on Wi-Fi',
          ),
          trailing: available
              ? FilledButton.tonal(
                  onPressed: () => showFirmwareConfirmSheet(context),
                  child: const Text('Update'),
                )
              : IconButton(
                  tooltip: 'Check now',
                  onPressed: connected && !checking
                      ? () => _check(context)
                      : null,
                  icon: checking
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Install pump updates automatically'),
          subtitle: Text(
            'The pump updates itself at a quiet moment: when it isn’t '
            'running and no scheduled fill is coming up.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          value: session.autoUpdate,
          onChanged: session.ready
              ? (v) async {
                  try {
                    await session.setAutoUpdate(v);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(_why(e))));
                    }
                  }
                }
              : null,
        ),
      ],
    );
  }
}

/// Scans through the pump and lists what it hears.
class _NetworkPicker extends StatefulWidget {
  const _NetworkPicker();

  @override
  State<_NetworkPicker> createState() => _NetworkPickerState();
}

class _NetworkPickerState extends State<_NetworkPicker> {
  List<WifiNetwork>? _nets;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _nets = null;
      _error = null;
    });
    try {
      final nets = await context.read<PumpSession>().wifiScan();
      if (mounted) setState(() => _nets = nets);
    } catch (e) {
      if (mounted) setState(() => _error = _why(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final nets = _nets;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Pick a network',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Scan again',
                onPressed: _scan,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const Text('The pump looks for 2.4 GHz networks.'),
          const SizedBox(height: 8),
          if (_error != null)
            Text(_error!)
          else if (nets == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (nets.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No networks found. Move the pump closer to the router.',
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final n in nets)
                    ListTile(
                      enabled: n.supported,
                      leading: Icon(
                        n.secured
                            ? Icons.wifi_lock_rounded
                            : Icons.wifi_rounded,
                      ),
                      title: Text(n.ssid),
                      subtitle: Text(
                        n.supported
                            ? WifiScreen.signalText(n.rssi)
                            : 'Not supported (needs a login)',
                      ),
                      onTap: n.supported
                          ? () => Navigator.pop(context, n)
                          : null,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
