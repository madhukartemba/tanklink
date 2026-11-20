import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../ble/pump_session.dart';
import '../ble/tanklink_uuids.dart';

/// Debug builds only: send a tank firmware file to the pump, which sends it
/// to the tank over LoRa (experimental). Shows both stages of progress.
class TankLoraUpdateScreen extends StatefulWidget {
  const TankLoraUpdateScreen({super.key});

  @override
  State<TankLoraUpdateScreen> createState() => _TankLoraUpdateScreenState();
}

class _TankLoraUpdateScreenState extends State<TankLoraUpdateScreen> {
  Uint8List? _image;
  String? _fileName;
  int? _node;
  double? _upload; // 0..1 while sending to the pump
  String? _error;

  static const _errors = {
    1: 'The tank never answered.',
    2: 'The tank couldn’t take the image.',
    3: 'Lost contact with the tank.',
    4: 'The tank was missing parts at the end.',
    5: 'The tank rejected the image (hash or signature).',
    6: 'No answer after sending.',
    7: 'Cancelled.',
    8: 'That sensor isn’t paired.',
    9: 'Stop the pump first.',
  };

  Future<void> _pick() async {
    final file = await FilePicker.pickFile();
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() {
      _image = bytes;
      _fileName = file.name;
    });
  }

  Future<void> _send(PumpSession s) async {
    setState(() {
      _upload = 0;
      _error = null;
    });
    try {
      await s.sendTankImageToPump(
        _image!,
        _node!,
        onProgress: (d, t) => setState(() => _upload = d / t),
      );
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _upload = null);
    }
  }

  String _stateText(int st) => switch (st) {
    TankLinkUuids.tankOtaWaiting =>
      'Waiting for the tank to wake (up to 5 min, or tap its button)',
    TankLinkUuids.tankOtaOffering => 'Tank awake, preparing',
    TankLinkUuids.tankOtaSending => 'Sending to the tank over LoRa',
    TankLinkUuids.tankOtaFinishing => 'Tank is checking the image',
    TankLinkUuids.tankOtaDone => 'Done: the tank is restarting',
    TankLinkUuids.tankOtaFailed => 'Failed',
    _ => 'Idle',
  };

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PumpSession>();
    final ota = s.tankOta;
    final busy = _upload != null || (ota?.busy ?? false);
    final pct = ota == null || ota.total == 0 ? null : ota.done / ota.total;
    return Scaffold(
      appBar: AppBar(title: const Text('Tank update over LoRa')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Experimental, debug build only.'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: busy ? null : _pick,
            icon: const Icon(Icons.folder_open_rounded),
            label: Text(_fileName ?? 'Pick tank_node.bin'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _node,
            decoration: const InputDecoration(
              labelText: 'Tank sensor',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final t in s.sensors)
                DropdownMenuItem(
                  value: t.index,
                  child: Text('Sensor ${t.index + 1} · ${t.idHex}'),
                ),
            ],
            onChanged: busy ? null : (v) => setState(() => _node = v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy || _image == null || _node == null || !s.ready
                ? null
                : () => _send(s),
            child: const Text('Send to pump'),
          ),
          if (_upload != null) ...[
            const SizedBox(height: 24),
            Text('Sending to the pump: ${(_upload! * 100).round()}%'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _upload),
          ],
          if (ota != null && ota.state != TankLinkUuids.tankOtaIdle) ...[
            const SizedBox(height: 24),
            Text(
              _stateText(ota.state),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: ota.state == TankLinkUuids.tankOtaSending
                  ? pct
                  : (ota.busy ? null : pct),
            ),
            const SizedBox(height: 6),
            Text(
              '${ota.done} of ${ota.total} chunks · ${ota.fast ? '500 kHz' : '125 kHz'}'
              '${ota.state == TankLinkUuids.tankOtaFailed ? '\n${_errors[ota.error] ?? 'Error ${ota.error}'}' : ''}',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (ota.busy)
                  TextButton(
                    onPressed: () => s.tankOtaCommand(0),
                    child: const Text('Cancel'),
                  ),
                if (ota.state == TankLinkUuids.tankOtaFailed) ...[
                  TextButton(
                    onPressed: () => s.tankOtaCommand(2),
                    child: const Text('Retry (fast)'),
                  ),
                  TextButton(
                    onPressed: () => s.tankOtaCommand(1),
                    child: const Text('Retry (125 kHz)'),
                  ),
                ],
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
