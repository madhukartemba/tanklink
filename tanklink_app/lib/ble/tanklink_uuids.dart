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

  /// The last fills, newest first.
  static final history = Guid('7f1a000f-ac01-4c8c-9b2e-74616e6b6c6e');

  /// Each sensor's daily battery low and high.
  static final battery = Guid('7f1a0010-ac01-4c8c-9b2e-74616e6b6c6e');

  /// Alerts (minor 6): the pump-wide alert key (read, signed in), and the
  /// last alerts the pump raised (read + notify, signed in).
  static final alertKey = Guid('7f1a0012-ac01-4c8c-9b2e-74616e6b6c6e');
  static final alertLog = Guid('7f1a0013-ac01-4c8c-9b2e-74616e6b6c6e');

  /// Pump advertising state bit: an alert is in the 7 bytes after the state
  /// byte (seq type arg tag[4]).
  static const advStateAlert = 0x04;
  static const alertTagLen = 4;

  /// Alert types (tl_alert_type_t in pump_alert.h).
  static const alertTankFull = 1;
  static const alertAutoOff = 2;
  static const alertPowerCut = 3;
  static const alertTankOffline = 4;
  static const alertBatteryLow = 5;
  static const alertTest = 6;
  static const alertSensorRemoved = 7;

  /// Raise a test alert on the pump (minor 6).
  static const cmdTestAlert = 0xAD;

  /// Give the pump its name (minor 8): the UTF-8 bytes, at most [pumpNameMax].
  static const cmdRenamePump = 0xAE;
  static const pumpNameMax = 24;

  /// Wi-Fi setup and status (minor 4).
  static final wifi = Guid('7f1a0011-ac01-4c8c-9b2e-74616e6b6c6e');

  /// Wifi write ops (byte 0).
  static const wifiOpSet = 0x01;
  static const wifiOpForget = 0x02;
  static const wifiOpScan = 0x03;
  static const wifiOpScanPage = 0x04;
  static const wifiOpStatus = 0x05;

  /// Networks per scan page.
  static const wifiScanPage = 8;

  /// History entry: started(u32) ran_sec(u32) slot started_by stopped_by pad.
  static const historyEntryLen = 12;

  /// History: total(1) start(1) count(1) then fills; write start(1) to pick
  /// the page. At most this many fills per read.
  static const historyPage = 40;

  /// Battery day: day(u16) min max.
  static const batteryDayLen = 4;

  /// Why a fill started or stopped (pump_cause_t in pump_history.h).
  static const causeUnknown = 0;
  static const causeApp = 1;
  static const causeButton = 2;
  static const causeSchedule = 3;
  static const causeTankFull = 4;
  static const causeAutoOff = 5;
  static const causePower = 6;
  static const causeSystem = 7;
  static const causeAutoFill = 8;

  static const tokenLen = 16;

  /// Auth: read gives a 16-byte nonce per connection; write the answer
  /// from `authResponse` in protocol.dart.
  static const nonceLen = 16;
  static const cmdUnpair = 0xF0;
  static const cmdFactoryReset = 0xF1;

  /// Open / close the pump's phone pairing window (pump protocol minor 2).
  static const cmdPairingOpen = 0xF2;
  static const cmdPairingClose = 0xF3;

  /// Keep only this phone's key: every other phone must be added again.
  static const cmdForgetOtherPhones = 0xF4;

  /// Pump protocol minor that has the two commands above and the
  /// advertising state byte below.
  static const pairingControlMinor = 2;

  /// Pump advertising: manufacturer data under [tankMfgCompanyId] (same
  /// 0xFFFF as the tank) holding one state byte.
  static const advStateClaimable = 0x01;
  static const advStatePaired = 0x02;
  static const cmdClearError = 0xE0;

  /// Dismiss the interrupted-fill notice.
  static const cmdDismissInterrupt = 0xE1;
  static const cmdTestBeep = 0xB1;

  /// Pump firmware over Wi-Fi (minor 5): look for an update now, install the
  /// one found, forget the "updated overnight" notice.
  static const cmdUpdateCheck = 0xAA;
  static const cmdUpdateInstall = 0xAB;
  static const cmdUpdateDismiss = 0xAC;
  static const cmdTankPair = 0xA1;

  /// Close the tank-pair window early (proto minor 3).
  static const cmdTankPairStop = 0xA3;

  /// sensor_id(6).
  static const cmdTankUnpair = 0xA2;
  static const cmdTankSelect = 0xA4;
  static const cmdTankRename = 0xA5;

  /// slot(1) minutes(1), 1–240 (the pump clamps; auto-off can't be off).
  static const cmdTankAutoOff = 0xA6;

  /// slot(1) on(1): fill by itself when the tank runs low (almost-empty
  /// float, or below the full float when that is its only one). Only for a
  /// tank with a sensor.
  static const cmdTankAutoFill = 0xA8;

  /// flow_dlpm(u16) watts(u16) price_centi(u16) currency(4): saved on the
  /// pump so every phone shows the same water and cost figures.
  static const cmdUsage = 0xA9;
  static const usageCurrencyLen = 4;

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
  static const pumpErrI2c = 6;
  static const pumpErrRtcMissing = 7;
  static const pumpErrRtcLost = 8;
  static const pumpErrRtcComm = 9;

  /// Tank sensor light codes, carried in the tank status and sensor list.
  static const tankErrNotPaired = 1;
  static const tankErrLoraMissing = 2;
  static const tankErrNoAck = 3;
  static const tankErrPairCancelled = 4;
  static const tankErrPairTimeout = 5;
  static const tankErrBattery = 6;
  static const tankErrUpdateFailed = 7;

  /// Tank characteristic: base fields, the tank BLE token at 19, then the
  /// interrupted-fill fields at 35.
  static const tankStatusTokenAt = 19;
  static const tankStatusInterruptAt = 35;
  static const tankStatusHwRevAt = 52;

  /// Selected tank sensor's own light code (0 = none).
  static const tankStatusFaultAt = 53;

  /// Pump-wide flags: bit 0 = the pump's clock lost power since it started.
  static const tankStatusPumpFlagsAt = 54;
  static const tankStatusClockLost = 0x01;

  /// u32, random and new every time the pump starts.
  static const tankStatusBootIdAt = 55;
  static const tankStatusLen = 59;

  static const interruptNone = 0;
  static const interruptPowerLost = 1;
  static const interruptBrownout = 2;
  static const interruptRestarted = 3;

  /// Warn when tank reports battery at or below this %.
  static const tankBatteryLowPct = 20;

  /// Match pump CONFIG_PUMP_TANK_STALE_SEC — used for live last-seen / online.
  static const tankStaleSec = 750;

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

  /// Starter profile (settings byte). Single-phase holds relay 1 closed while
  /// the pump runs (pump protocol minor 9).
  static const starterNone = 0;
  static const starterTwoButton = 1;
  static const starterSinglePhase = 2;

  static const relayPulseMsDefault = 1000;
  static const relayPulseMsMin = 50;
  static const relayPulseMsMax = 2000;
}
