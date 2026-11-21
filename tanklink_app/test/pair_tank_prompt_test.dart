// Pairing a tank from the prompt shown after adding a pump must land on the
// home screen, not a blank page (the dialog used to pop once per update).

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:tanklink/ble/pump_session.dart';
import 'package:tanklink/screens/pair_tank_prompt_screen.dart';

class _FakeSession extends PumpSession {
  int stops = 0;

  @override
  Future<void> startTankPair() async {
    tankPairing = true;
    notifyListeners();
  }

  @override
  Future<void> stopTankPair() async {
    stops++;
    tankPairing = false;
    notifyListeners();
  }
}

void main() {
  testWidgets('tank paired: back on home, nothing else popped', (t) async {
    final session = _FakeSession();
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      ChangeNotifierProvider<PumpSession>.value(
        value: session,
        child: MaterialApp(
          navigatorKey: nav,
          home: const Scaffold(body: Text('HOME')),
        ),
      ),
    );
    // Home -> Add pump -> Pair tank prompt, as after adding a pump.
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('ADD')),
      ),
    );
    await t.pumpAndSettle();
    nav.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const PairTankPromptScreen()),
    );
    await t.pumpAndSettle();

    await t.tap(find.text('Pair tank sensor'));
    // The dialog's progress bar never settles: pump a fixed time instead.
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Listening…'), findsOneWidget);

    // The tank pairs; the pump sends tank, tanks and sensors updates in a row.
    session.tankBound = true;
    session.tankPairing = false;
    for (var i = 0; i < 4; i++) {
      session.notifyListeners();
      await t.pump();
    }
    await t.pumpAndSettle();

    expect(find.text('HOME'), findsOneWidget);
    expect(nav.currentState!.canPop(), isFalse); // home is the only route
  });

  testWidgets('Cancel while listening stops pairing, closes only the dialog', (
    t,
  ) async {
    final session = _FakeSession();
    await t.pumpWidget(
      ChangeNotifierProvider<PumpSession>.value(
        value: session,
        child: const MaterialApp(home: PairTankPromptScreen()),
      ),
    );
    await t.tap(find.text('Pair tank sensor'));
    // The dialog's progress bar never settles: pump a fixed time instead.
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('Listening…'), findsNothing);
    expect(find.text('Pair a tank sensor?'), findsOneWidget);
    // The pump is told to stop listening (its light goes back to standby).
    expect(session.stops, 1);
    expect(session.tankPairing, isFalse);
  });
}
