import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Must match pump_node/main/tanklink_uuid.h
class TankLinkUuids {
  static const deviceNamePrefix = 'TankLink-';
  static const deviceName = 'TankLink-Pump';

  static final service = Guid('7f1a0001-ac01-4c8c-9b2e-74616e6b6c6e');
  static final info = Guid('7f1a0002-ac01-4c8c-9b2e-74616e6b6c6e');
  static final pair = Guid('7f1a0003-ac01-4c8c-9b2e-74616e6b6c6e');
  static final auth = Guid('7f1a0004-ac01-4c8c-9b2e-74616e6b6c6e');
  static final state = Guid('7f1a0005-ac01-4c8c-9b2e-74616e6b6c6e');
  static final cmd = Guid('7f1a0006-ac01-4c8c-9b2e-74616e6b6c6e');
  static final settings = Guid('7f1a0007-ac01-4c8c-9b2e-74616e6b6c6e');

  static const tokenLen = 16;
  static const cmdUnpair = 0xF0;
  static const cmdTestBeep = 0xB1;

  static const buzzEnabled = 1 << 0;
  static const buzzOnButton = 1 << 1;
  static const buzzOnPump = 1 << 2;
  static const buzzOnAutoOff = 1 << 3;
}
