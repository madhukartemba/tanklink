import 'package:material_ui/material_ui.dart';

import 'error_text.dart';

/// Run [action]; if it fails, say why in a snackbar instead of failing silently.
Future<void> runOrSnack(
  BuildContext context,
  Future<void> Function() action,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(errorMessage(e))));
  }
}
