import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Must match pump_node/main/tanklink_uuid.h
class TankLinkUuids {
  static const deviceNamePrefix = 'TankLink-';
  static const deviceName = 'TankLink-Pump';
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

  static const tokenLen = 16;
  static const cmdUnpair = 0xF0;
  static const cmdFactoryReset = 0xF1;
  static const cmdClearError = 0xE0;
  static const cmdTestBeep = 0xB1;
  static const cmdTankPair = 0xA1;
  static const cmdTankUnpair = 0xA2;

  static const tankFlagFull = 1 << 0;
  static const tankFlagEmpty = 1 << 1;
  static const tankFlagBtn = 1 << 2;
  static const tankFlagPairing = 1 << 3;

  /** Pump NeoPixel / home-banner codes (match docs/ERROR_CODES.md). */
  static const pumpErrNone = 0;
  static const pumpErrTankFull = 1;
  static const pumpErrLoraMissing = 2;
  static const pumpErrTankOffline = 3;
  static const pumpErrBlocked = 4;
  static const pumpErrNotPaired = 5;

  /** Base tank char length (bound…snr…last_error). Token may follow. */
  static const tankStatusLen = 19;
  static const tankStatusWithTokenLen = 35;
  /** Warn when tank reports battery at or below this %. */
  static const tankBatteryLowPct = 20;
  /** Match pump CONFIG_PUMP_TANK_STALE_SEC — used for live last-seen / online. */
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

  /** Starter / contactor profile (settings byte). */
  static const starterNone = 0;
  static const starterTwoButton = 1;

  static const relayPulseMsDefault = 400;
  static const relayPulseMsMin = 50;
  static const relayPulseMsMax = 2000;
}
