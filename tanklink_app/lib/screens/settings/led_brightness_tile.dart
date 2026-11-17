import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../ble/pump_session.dart';

class LedBrightnessTile extends StatefulWidget {
  const LedBrightnessTile({super.key, required this.ready});

  final bool ready;

  @override
  State<LedBrightnessTile> createState() => _LedBrightnessTileState();
}

class _LedBrightnessTileState extends State<LedBrightnessTile> {
  late int _draft;
  bool _hydrated = false;

  void _hydrate(PumpSession session) {
    if (_hydrated) return;
    _draft = session.ledBrightness.clamp(1, 100);
    _hydrated = true;
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<PumpSession>();
    final scheme = Theme.of(context).colorScheme;
    _hydrate(session);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.light_mode_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Light brightness',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    !widget.ready ? 'Connect to change' : '$_draft%',
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
        if (widget.ready) ...[
          // Indent to match title text (icon 24 + gap 16).
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Slider(
              min: 1,
              max: 100,
              divisions: 99,
              value: _draft.toDouble(),
              label: '$_draft%',
              onChanged: (v) => setState(() => _draft = v.round()),
              onChangeEnd: (v) => session.setLedBrightness(v.round()),
            ),
          ),
        ],
      ],
    );
  }
}
