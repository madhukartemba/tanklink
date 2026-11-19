/// Names for the pump and tank light codes. Keep in step with docs/ERROR_CODES.md.
class WarnText {
  const WarnText(this.code, this.name, this.detail);

  final int code;
  final String name;
  final String detail;
}

class TankLinkErrors {
  static const pump = <WarnText>[
    WarnText(
      1,
      'Tank is full',
      'The tank is full, so the pump will not start.',
    ),
    WarnText(
      2,
      'Tank link not working',
      'The pump cannot talk to the tank sensor. Check its wiring.',
    ),
    WarnText(
      3,
      'Tank out of range',
      'The pump has not heard from the tank sensor recently. Check its power and distance.',
    ),
    WarnText(
      4,
      'Pump start blocked',
      'The pump is busy with an update or setup. Wait a moment and try again.',
    ),
    WarnText(5, 'Pump not set up', 'Set up this pump in the app first.'),
    WarnText(
      6,
      'Clock wire problem',
      'The pump could not start the wire to its clock chip. Check the clock wiring.',
    ),
    WarnText(
      7,
      'Clock chip missing',
      'The pump cannot find its clock chip. Check that it is fitted and wired.',
    ),
    WarnText(
      8,
      'Clock lost the time',
      'The clock chip lost power. Open the app near the pump so it can set the time again.',
    ),
    WarnText(
      9,
      'Clock chip not answering',
      'The clock chip stopped answering. Check its wiring and power.',
    ),
  ];

  static const tank = <WarnText>[
    WarnText(
      1,
      'Tank not set up',
      'The tank was pressed but is not connected to a pump yet. '
          'Start setup on the pump, then hold the tank button for about 3 seconds.',
    ),
    WarnText(
      2,
      'Tank radio problem',
      'The tank’s radio did not start. Check its wiring and power.',
    ),
    WarnText(
      3,
      'Pump not answering',
      'The tank sent a message but the pump did not reply. '
          'Check the distance and power, and make sure this tank is still set up with this pump.',
    ),
    WarnText(
      4,
      'Setup cancelled',
      'The tank button was pressed once during setup to cancel.',
    ),
    WarnText(
      5,
      'Setup timed out',
      'The pump did not confirm setup in time. Start setup again and hold the tank button for 3 seconds.',
    ),
    WarnText(
      6,
      'Tank battery sense failed',
      'The tank cannot read its battery. Check the battery wiring.',
    ),
  ];

  static WarnText? _of(List<WarnText> list, int code) {
    for (final e in list) {
      if (e.code == code) return e;
    }
    return null;
  }

  static String? pumpTitle(int code) => _of(pump, code)?.name;
  static String? pumpDetail(int code) => _of(pump, code)?.detail;
  static String? tankTitle(int code) => _of(tank, code)?.name;
  static String? tankDetail(int code) => _of(tank, code)?.detail;
}
