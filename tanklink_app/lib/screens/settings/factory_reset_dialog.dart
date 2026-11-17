import 'package:material_ui/material_ui.dart';

class FactoryResetDialog extends StatefulWidget {
  const FactoryResetDialog({super.key});

  @override
  State<FactoryResetDialog> createState() => _FactoryResetDialogState();
}

class _FactoryResetDialogState extends State<FactoryResetDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _matches => _controller.text.trim().toUpperCase() == 'RESET';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Factory reset?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Erases this pump’s settings, its link to your phone, and its tank '
            'sensor link. The pump then restarts. Type RESET to confirm.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Type RESET',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_matches) Navigator.pop(context, true);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _matches ? () => Navigator.pop(context, true) : null,
          child: const Text('Factory reset'),
        ),
      ],
    );
  }
}
