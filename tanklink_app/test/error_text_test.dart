import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/util/error_text.dart';

void main() {
  test('StateError shows its own message', () {
    expect(
      errorMessage(StateError('Stop the pump first')),
      'Stop the pump first',
    );
  });

  test('a long platform error is cut to one short line', () {
    final long = Exception('${'x' * 400}\nstack line');
    final msg = errorMessage(long);
    expect(msg.length, lessThanOrEqualTo(140));
    expect(msg.endsWith('…'), isTrue);
    expect(msg.contains('\n'), isFalse);
  });

  test('timeouts read plainly', () {
    expect(errorMessage(TimeoutException('x')), contains('didn’t answer'));
  });
}
