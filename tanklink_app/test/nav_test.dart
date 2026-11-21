import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tanklink/util/nav.dart';

void main() {
  testWidgets('popSelf closes a dialog once, never the screen under it', (
    tester,
  ) async {
    late BuildContext dialogContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (home) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: home,
                  builder: (ctx) {
                    dialogContext = ctx;
                    return const AlertDialog(title: Text('Update complete'));
                  },
                ),
                child: const Text('Home'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Update complete'), findsOneWidget);

    // The Done tap and a late automatic close, in the same frame.
    expect(popSelf(dialogContext), isTrue);
    expect(popSelf(dialogContext), isFalse);
    await tester.pumpAndSettle();

    expect(find.text('Update complete'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });
}
