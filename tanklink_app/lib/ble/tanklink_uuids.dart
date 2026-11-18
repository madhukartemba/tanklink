import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Must match pump_node/main/tanklink_uuid.h and
/// tank_node/main/tanklink_ble_uuid.h.
class TankLinkUuids {
  /// BLE protocol major this app speaks. A pump or tank reporting another
  /// major is only offered a firmware update (see docs/PROTOCOL.md).
  static const protoMajor = 1;

  /// Pump Info: proto_major proto_minor hw_rev paired flags device_id(6)
  /// fw(3) run_secs(u32). Frozen; later versions only append.
  static const infoLen = 18;

  static const deviceNamePrefix = 'TankLink-';
  static const tankAdvNamePrefix = 'TL-Tank-';
  static const tankMfgCompanyId = 0xFFFF;

  static final service = Guid('7f1a0001-ac01-4c8c-9b2e-74616e6b6c6e');
  static final info = Guid('7f1a0002-ac01-4c8c-9b2e-74616e6b6c6e');
  static final pair = Guid('7f1a0003-ac01-4c8c-9b2e-74616e6b6c6e');
  static final auth = Guid('7f1a0004-ac01-4c8c-9b2e-74616e6b6c6e');
  static final state = Guid('7f1a0005-ac01-4c8c-9b2e-74616e6b6c6e');
  static final cmd = Guid('7f1a0006-ac01-4c8c-9b2e-74616e6b6c6e');
  static final settings = Guid('7f1a0007-ac01-4c8c-9b2e-74616e6b6c6e');
  static final otaCtrl = Guid('7f1a0008-ac01-4c8c-9b2e-74616e6b6c6e');
  static final otaData = Guid('7f1a0009-ac01-4c8c-9b2e-74616e6b6c6e');
  static final otaStatus = Guid('7f1a000a-ac01-4c8c-9b2e-74616e6b6c6e');
  static final tank = Guid('7f1a000b-ac01-4c8c-9b2e-74616e6b6c6e');
  static final sched = Guid('7f1a000c-ac01-4c8c-9b2e-74616e6b6c6e');
  static final tanks = Guid('7f1a000d-ac01-4c8c-9b2e-74616e6b6c6e');

  /// Paired tank sensors.
  static final sensors = Guid('7f1a000e-ac01-4c8c-9b2e-74616e6b6c6e');

  static const tokenLen = 16;
  static const cmdUnpair = 0xF0;
  static const cmdFactoryReset = 0xF1;
  static const cmdClearError = 0xE0;

  /// Dismiss the interrupted-fill notice.
  static const cmdDismissInterrupt = 0xE1;
  static const cmdTestBeep = 0xB1;
  static const cmdTankPair = 0xA1;

  /// sensor_id(6).
  static const cmdTankUnpair = 0xA2;
  static const cmdTankSelect = 0xA4;
  static const cmdTankRename = 0xA5;

  /// slot(1) minutes(1), 0 = off.
  static const cmdTankAutoOff = 0xA6;

  /// sensor_id(6) mode(1): one sensor's float mode.
  static const cmdSensorMode = 0xA7;

  static const sensorModeOff = 0;
  static const sensorModeEmpty = 1;
  static const sensorModeTwo = 2;
  static const tankNameLen = 16;

  /// Tank sensors one pump can pair, and tank slots (two per sensor).
  static const sensorMax = 4;
  static const tankSlotMax = sensorMax * 2;
  static const sensorNone = 0xFF;

  /// Sensors entry: index id(6) mode raw_flags battery online age(u16) rssi
  /// snr fw(3) hw_rev token(16).
  static const sensorEntryLen = 35;

  /// Tanks entry: slot_index sensor_pin sensor_index auto_off_min name(16).
  static const tanksEntryLen = 4 + tankNameLen;
  static const autoOffMaxMin = 240;

  static const schedOpSetClock = 0x01;
  static const schedOpSetList = 0x02;
  static const schedMax = 4;

  static const tankFlagFull = 1 << 0;
  static const tankFlagEmpty = 1 << 1;
  static const tankFlagBtn = 1 << 2;
  static const tankFlagPairing = 1 << 3;

  /// Pump NeoPixel / home-banner codes (match docs/ERROR_CODES.md).
  static const pumpErrNone = 0;
  static const pumpErrTankFull = 1;
  static const pumpErrLoraMissing = 2;
  static const pumpErrTankOffline = 3;
  static const pumpErrBlocked = 4;
  static const pumpErrNotPaired = 5;

  /// Tank characteristic: base fields, the tank BLE token at 19, then the
  /// interrupted-fill fields at 35.
  static const tankStatusTokenAt = 19;
  static const tankStatusInterruptAt = 35;
  static const tankStatusHwRevAt = 52;
  static const tankStatusLen = 53;

  static const interruptNone = 0;
  static const interruptPowerLost = 1;
  static const interruptBrownout = 2;
  static const interruptRestarted = 3;

  /// Warn when tank reports battery at or below this %.
  static const tankBatteryLowPct = 20;

  /// Match pump CONFIG_PUMP_TANK_STALE_SEC — used for live last-seen / online.
  static const tankStaleSec = 1500;

  static const otaOpStart = 0x01;
  static const otaOpAbort = 0x02;
  static const otaOpFinish = 0x03;

  static const otaStIdle = 0;
  static const otaStReady = 1;
  static const otaStWriting = 2;
  static const otaStVerifyOk = 3;
  static const otaStRebooting = 4;
  static const otaStErr = 5;

  static const buzzEnabled = 1 << 0;
  static const buzzOnButton = 1 << 1;
  static const buzzOnPump = 1 << 2;
  static const buzzOnAutoOff = 1 << 3;

  /// Starter / contactor profile (settings byte).
  static const starterNone = 0;
  static const starterTwoButton = 1;

  static const relayPulseMsDefault = 1000;
  static const relayPulseMsMin = 50;
  static const relayPulseMsMax = 2000;
}
