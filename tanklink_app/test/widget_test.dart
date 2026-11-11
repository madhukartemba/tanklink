import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/main.dart';

void main() {
  testWidgets('TankLink app builds', (tester) async {
    await tester.pumpWidget(const TankLinkApp());
    expect(find.text('TankLink'), findsOneWidget);
  });
}
