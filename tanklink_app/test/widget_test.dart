import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tanklink/main.dart';
import 'package:tanklink/util/app_prefs.dart';

void main() {
  testWidgets('TankLink app builds', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AppPrefs.load();
    await tester.pumpWidget(TankLinkApp(prefs: prefs));
    expect(find.text('TankLink'), findsOneWidget);
  });
}
