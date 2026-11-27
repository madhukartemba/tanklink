import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/link/app_link.dart';

void main() {
  test('a link naming a pump gives its serial', () {
    expect(pumpSerialFromLink('https://tanklink.madhukartemba.in/pump/a1b2'), 'A1B2');
    expect(pumpSerialFromLink('https://tanklink.madhukartemba.in/pump/A1B2/'), 'A1B2');
  });

  test('other links name no pump', () {
    expect(pumpSerialFromLink(null), isNull);
    expect(pumpSerialFromLink('https://tanklink.madhukartemba.in/pump'), isNull);
    expect(pumpSerialFromLink('https://tanklink.madhukartemba.in/pump/A1B'), isNull);
    expect(pumpSerialFromLink('https://tanklink.madhukartemba.in/pump/ZZZZ'), isNull);
    expect(pumpSerialFromLink('http://tanklink.madhukartemba.in/pump/A1B2'), isNull);
    expect(pumpSerialFromLink('https://example.com/pump/A1B2'), isNull);
  });
}
