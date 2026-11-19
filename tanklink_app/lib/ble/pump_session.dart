import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diag/app_log.dart';
import '../util/error_text.dart';
import 'battery_trend.dart';
import 'models.dart';
import 'ota_upload.dart';
import 'protocol.dart';
import 'tanklink_uuids.dart';

export 'models.dart';
export 'battery_trend.dart';
export 'protocol.dart' show TankSensor;

class PumpSession extends ChangeNotifier {
  final List<SavedPump> pumps = [];
  String? selectedRemoteId;

  String _status = 'Starting…';

  /// The status line under the pump name. Every change is logged, so the
  /// app log shows what the user saw.
  String get status => _status;
  set status(String v) {
    if (v == _status) return;
    _status = v;
    AppLog.i('pump', 'Status: $v');
  }

  String firmware = '';

  /// From Info. 0 until the pump has been read.
  int pumpProtoMajor = 0;
  int pumpProtoMinor = 0;
  int pumpHwRev = 0;

  /// Tank board revision, relayed by the pump. 0 = unknown.
  int tankHwRev = 0;
  int runSeconds = 0;
  int buzzerFlags =
      TankLinkUuids.buzzEnabled |
      TankLinkUuids.buzzOnButton |
      TankLinkUuids.buzzOnPump |
      TankLinkUuids.buzzOnAutoOff;
  int buzzerTone = 0; // click / soft / sharp / double
  int ledBrightness = 70; // 1-100
  int starterType = TankLinkUuids.starterNone;
  int relayPulseMs = TankLinkUuids.relayPulseMsDefault;

  int activeSlot = 0;
  List<TankSlot> tanks = [];

  /// Paired tank sensors, up to [TankLinkUuids.sensorMax].
  List<TankSensor> sensors = [];

  /// The pump's last fills, newest first.
  List<FillRecord> fills = [];

  /// Each sensor's daily battery low/high, by sensor index, oldest first.
  Map<int, List<BatteryDay>> batteryLogs = {};

  /// Wall-clock estimate of each sensor's last packet, by sensor index.
  final Map<int, DateTime> _sensorHeardAt = {};
  bool connecting = false;
  bool connectFailed = false;
  bool scanning = false;
  bool connected = false;
  bool authed = false;
  bool pumpOn = false;
  bool tankBound = false;
  bool tankPairing = false;
  bool tankOnline = false;
  String tankIdHex = '';
  String tankFw = '';
  Uint8List? tankBleToken;
  int tankFlags = 0;
  int tankBatteryPct = 0;

  /// Wall-clock estimate of last LoRa RX (from GATT age_sec snapshots).
  DateTime? _tankLastHeardAt;

  /// Last LoRa packet RSSI (dBm); null if unknown.
  int? tankRssiDbm;

  /// Phone-to-pump BLE RSSI (dBm); null when disconnected or not yet read.
  int? bleRssiDbm;

  /// Last LoRa packet SNR (dB); null if unknown.
  int? tankSnrDb;

  /// Last pump NeoPixel / start-deny error (0 = none).
  int pumpLastError = 0;

  /// Selected tank sensor's own light code, 0 when it has none.
  int tankFault = 0;

  /// Debug builds only: codes that replace the pump's reported ones so the
  /// error banners and reports can be tried without breaking hardware.
  int? simPumpError;
  int? simTankFault;

  /// Set when a fill was cut short by a power cut or restart, until dismissed.
  FillInterruption? fillInterruption;
  bool pumpClockValid = false;

  /// The DS3231 holds a trusted time, so schedules survive a restart.
  bool pumpRtcOk = false;
  int pumpClockHour = 0;
  int pumpClockMinute = 0;
  List<FillSchedule> schedules = [];
  final List<ScanResult> scanResults = [];

  BluetoothDevice? _device;
  BluetoothCharacteristic? _info;
  BluetoothCharacteristic? _pair;
  BluetoothCharacteristic? _auth;
  BluetoothCharacteristic? _state;
  BluetoothCharacteristic? _cmd;
  BluetoothCharacteristic? _settings;
  BluetoothCharacteristic? _otaCtrl;
  BluetoothCharacteristic? _otaData;
  BluetoothCharacteristic? _otaStatus;
  BluetoothCharacteristic? _tank;
  BluetoothCharacteristic? _sched;
  BluetoothCharacteristic? _tanks;
  BluetoothCharacteristic? _sensorsChr;
  BluetoothCharacteristic? _historyChr;
  BluetoothCharacteristic? _batteryChr;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _pairNotifySub;
  StreamSubscription<List<int>>? _stateNotifySub;
  StreamSubscription<List<int>>? _tankNotifySub;
  StreamSubscription<List<int>>? _schedNotifySub;
  StreamSubscription<List<int>>? _tanksNotifySub;
  StreamSubscription<List<int>>? _sensorsNotifySub;
  StreamSubscription<List<int>>? _historyNotifySub;
  StreamSubscription<List<int>>? _batteryNotifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _runTicker;
  Timer? _ageTicker;
  Timer? _clockSyncTimer;
  Timer? _rssiTimer;
  bool _rssiBusy = false;

  /// The pump speaks a BLE protocol major this app does not. Only a firmware
  /// update is possible until the pump or the app is updated.
  bool get protocolMismatch =>
      pumpProtoMajor != 0 && pumpProtoMajor != TankLinkUuids.protoMajor;

  /// True when the app needs updating rather than the pump.
  bool get pumpNeedsNewerApp => pumpProtoMajor > TankLinkUuids.protoMajor;

  /// Connected, signed in, and speaking the same protocol: safe to control.
  bool get ready => authed && connected && !protocolMismatch;

  bool get tankOtaReady =>
      tankBound &&
      tankBleToken != null &&
      tankBleToken!.length == TankLinkUuids.tokenLen &&
      tankBleToken!.any((b) => b != 0);

  /// Float mode of the selected tank's sensor (each sensor has its own).
  int get sensorMode => activeSensor?.mode ?? TankLinkUuids.sensorModeOff;

  bool get emptyFloatConnected => sensorMode == TankLinkUuids.sensorModeEmpty;

  /// More than one tank to pick from (several sensors, or two-tank mode).
  bool get multiTank => tanks.length > 1;

  bool get canAddSensor => sensors.length < TankLinkUuids.sensorMax;

  TankSensor? sensorAt(int index) {
    for (final s in sensors) {
      if (s.index == index) return s;
    }
    return null;
  }

  /// The sensor whose float reports [slot]'s level.
  TankSensor? sensorForSlot(TankSlot slot) => sensorAt(slot.node);

  /// The selected tank's sensor.
  TankSensor? get activeSensor {
    final slot = slotAt(activeSlot);
    return slot == null ? null : sensorForSlot(slot);
  }

  /// Tanks whose level comes from [sensor].
  List<TankSlot> slotsOf(TankSensor sensor) => [
    for (final t in tanks)
      if (t.node == sensor.index) t,
  ];

  /// Removing [sensor] now would stop the running fill's tank from reporting.
  bool sensorFeedsRunningFill(TankSensor sensor) =>
      pumpOn && slotsOf(sensor).any((t) => t.index == activeSlot);

  int? sensorAgeSec(TankSensor sensor) =>
      _liveAge(_sensorHeardAt[sensor.index]);

  bool sensorOnline(TankSensor sensor) {
    final age = sensorAgeSec(sensor);
    return sensor.online && age != null && age <= TankLinkUuids.tankStaleSec;
  }

  String sensorAgeLabel(TankSensor sensor) => ageLabel(sensorAgeSec(sensor));

  String sensorSignalLabel(TankSensor sensor) =>
      signalLabel(sensor.rssiDbm, sensorOnline(sensor));

  bool sensorBatteryLow(TankSensor sensor) =>
      sensorOnline(sensor) &&
      sensor.batteryPct > 0 &&
      sensor.batteryPct <= TankLinkUuids.tankBatteryLowPct;

  /// Battery trend from the pump's daily log for [sensor].
  BatteryOutlook batteryOutlook(TankSensor sensor) =>
      BatteryOutlook.from(batteryLogs[sensor.index] ?? const []);

  /// The tank's sensor is paired and heard recently.
  bool slotOnline(TankSlot slot) {
    final s = sensorForSlot(slot);
    return s != null && sensorOnline(s);
  }

  bool get tankFull => (tankFlags & TankLinkUuids.tankFlagFull) != 0;
  bool get tankEmpty =>
      sensorMode == TankLinkUuids.sensorModeEmpty &&
      (tankFlags & TankLinkUuids.tankFlagEmpty) != 0;
  bool get tankBatteryLow =>
      tankBound &&
      tankOnline &&
      tankBatteryPct > 0 &&
      tankBatteryPct <= TankLinkUuids.tankBatteryLowPct;

  String get tankShortId {
    if (tankIdHex.length < 4) return '----';
    return tankIdHex.substring(tankIdHex.length - 4).toUpperCase();
  }

  String get tankLevelLabel {
    if (tankFull) return 'Full';
    if (tankEmpty) return 'Almost empty';
    if (emptyFloatConnected) return 'Half full';
    return 'Ok';
  }

  String tankNameFor(int slot) {
    for (final t in tanks) {
      if (t.index == slot && t.name.isNotEmpty) return t.name;
    }
    return 'Tank ${slot + 1}';
  }

  String get activeTankName => tankNameFor(activeSlot);

  TankSlot? slotAt(int index) {
    for (final t in tanks) {
      if (t.index == index) return t;
    }
    return null;
  }

  /// Auto-off of the tank a fill would go to now. 0 = off.
  int get autoOffMin => autoOffMinFor(activeSlot);

  int autoOffMinFor(int slot) => slotAt(slot)?.autoOffMin ?? 0;

  /// [slot]'s own float says full, from its own sensor's last packet.
  bool slotIsFull(TankSlot slot) {
    final s = sensorForSlot(slot);
    if (s == null || !sensorOnline(s)) return false;
    // Raw pin bits: bit 0 is the sensor 1 pin, bit 1 the sensor 2 pin.
    final bit = slot.sensor == 1 && s.mode == TankLinkUuids.sensorModeTwo
        ? 1 << 1
        : 1 << 0;
    return (s.rawFlags & bit) != 0;
  }

  static int? _liveAge(DateTime? at) {
    if (at == null) return null;
    final s = DateTime.now().difference(at).inSeconds;
    if (s < 0) return 0;
    if (s > 0xFFFE) return 0xFFFE;
    return s;
  }

  /// Live seconds since last tank LoRa packet (ticks with UI timer).
  int? get tankAgeSec => _liveAge(_tankLastHeardAt);

  String get tankAgeLabel => ageLabel(tankAgeSec);

  static String ageLabel(int? age) {
    if (age == null) return 'Never heard';
    if (age < 10) return 'Just now';
    if (age < 60) return '${age}s ago';
    if (age < 3600) return '${age ~/ 60}m ago';
    if (age < 86400) {
      final h = age ~/ 3600;
      final m = (age % 3600) ~/ 60;
      return m == 0 ? '${h}h ago' : '${h}h ${m}m ago';
    }
    return '${age ~/ 86400}d ago';
  }

  /// 0..1 relative LoRa quality from RSSI (−120 weak … −40 strong).
  double get tankSignalQuality {
    final r = tankRssiDbm;
    if (r == null || !tankOnline) return 0;
    return ((r + 120) / 80).clamp(0.0, 1.0);
  }

  String get tankSignalLabel {
    if (!tankBound) return '—';
    return signalLabel(tankRssiDbm, tankOnline);
  }

  static String signalLabel(int? rssi, bool online) {
    if (!online || rssi == null) return 'No signal';
    final q = ((rssi + 120) / 80).clamp(0.0, 1.0);
    if (q >= 0.75) return 'Strong';
    if (q >= 0.45) return 'Good';
    if (q >= 0.25) return 'Fair';
    return 'Weak';
  }

  String? get pumpErrorTitle => TankLinkErrors.pumpTitle(pumpLastError);

  String? get pumpErrorDetail => TankLinkErrors.pumpDetail(pumpLastError);

  String? get tankFaultTitle => TankLinkErrors.tankTitle(tankFault);

  String? get tankFaultDetail => TankLinkErrors.tankDetail(tankFault);

  bool get canStartPump {
    if (!authed || !connected) return false;
    if (tankBound && tankOnline && tankFull) return false;
    return true;
  }

  SavedPump? get selected {
    if (selectedRemoteId == null) return null;
    for (final p in pumps) {
      if (p.remoteId == selectedRemoteId) return p;
    }
    return pumps.isEmpty ? null : pumps.first;
  }

  bool get hasPumps => pumps.isNotEmpty;

  String get runLabel {
    final s = runSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    if (m >= 60) {
      final h = m ~/ 60;
      final mm = m % 60;
      return '${h}h ${mm.toString().padLeft(2, '0')}m';
    }
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    final listRaw = prefs.getString('saved_pumps');
    if (listRaw != null) {
      final list = (jsonDecode(listRaw) as List)
          .cast<Map<String, dynamic>>()
          .map(SavedPump.fromJson)
          .whereType<SavedPump>()
          .toList();
      pumps
        ..clear()
        ..addAll(list);
    }

    selectedRemoteId =
        prefs.getString('selected_pump_id') ?? pumps.firstOrNull?.remoteId;

    if (selected == null) {
      status = 'Add a pump to get started';
      notifyListeners();
      return;
    }

    status = 'Connecting to ${selected!.name}…';
    notifyListeners();
    await connectSelected();
  }

  Future<void> onAppResumed() async {
    if (selected == null) return;
    if (connected && authed) return;
    if (connecting) return;
    await connectSelected();
  }

  Future<void> _persistAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'saved_pumps',
      jsonEncode(pumps.map((p) => p.toJson()).toList()),
    );
    if (selectedRemoteId != null) {
      await prefs.setString('selected_pump_id', selectedRemoteId!);
    } else {
      await prefs.remove('selected_pump_id');
    }
  }

  Future<void> _upsertPump(SavedPump pump, {bool select = true}) async {
    final i = pumps.indexWhere((p) => p.remoteId == pump.remoteId);
    if (i >= 0) {
      pumps[i] = pump;
    } else {
      pumps.add(pump);
    }
    if (select) {
      selectedRemoteId = pump.remoteId;
    }
    await _persistAll();
    notifyListeners();
  }

  Future<void> selectPump(SavedPump pump) async {
    if (selectedRemoteId == pump.remoteId && (connected || connecting)) {
      return;
    }
    await disconnect();
    selectedRemoteId = pump.remoteId;
    await _persistAll();
    notifyListeners();
    await connectSelected();
  }

  Future<void> renamePump(SavedPump pump, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _upsertPump(pump.copyWith(name: trimmed), select: false);
    if (selectedRemoteId == pump.remoteId) {
      notifyListeners();
    }
  }

  Future<void> forgetPump(SavedPump pump) async {
    final wasSelected = selectedRemoteId == pump.remoteId;
    if (wasSelected) {
      await disconnect();
    }
    pumps.removeWhere((p) => p.remoteId == pump.remoteId);
    if (wasSelected) {
      selectedRemoteId = pumps.firstOrNull?.remoteId;
    }
    await _persistAll();
    if (selected != null) {
      status = 'Select a pump';
      notifyListeners();
      await connectSelected();
    } else {
      status = 'Add a pump to get started';
      notifyListeners();
    }
  }

  Future<void> connectSelected() async {
    final pump = selected;
    if (pump == null) {
      status = 'No pump selected';
      connectFailed = false;
      notifyListeners();
      return;
    }
    connecting = true;
    connectFailed = false;
    status = 'Connecting to ${pump.name}…';
    notifyListeners();

    try {
      // Direct connect often fails on Android after a cold start while another
      // phone is already linked — scan first so the stack can see advertising.
      final device = await _resolveDeviceForConnect(pump);
      await _connectAndDiscover(device);
      final tokenPump = selected ?? pump;
      try {
        await _auth!.write(tokenPump.token, withoutResponse: false);
      } catch (e) {
        AppLog.w('ble', 'Auth write failed: $e');
        await disconnect();
        connecting = false;
        connectFailed = true;
        status = 'Auth failed — hold pump 5s, then Add pump again';
        notifyListeners();
        return;
      }
      authed = true;
      await _startSession();
      connecting = false;
      connectFailed = false;
      notifyListeners();
    } catch (e) {
      AppLog.w('ble', 'Connect failed: $e');
      await disconnect();
      connecting = false;
      connectFailed = true;
      status = 'Couldn’t connect';
      notifyListeners();
    }
  }

  /// Find the saved pump via a short scan (required when another central is
  /// already connected and Android's address cache is cold).
  Future<BluetoothDevice> _resolveDeviceForConnect(SavedPump pump) async {
    try {
      for (final d in FlutterBluePlus.connectedDevices) {
        if (d.remoteId.str == pump.remoteId) {
          return d;
        }
      }
    } catch (_) {}

    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return BluetoothDevice.fromId(pump.remoteId);
    }

    final found = Completer<BluetoothDevice>();
    StreamSubscription<List<ScanResult>>? sub;
    sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (_scanMatchesSavedPump(r, pump) && !found.isCompleted) {
          found.complete(r.device);
        }
      }
    });

    try {
      try {
        await FlutterBluePlus.startScan(
          withServices: [TankLinkUuids.service],
          timeout: const Duration(seconds: 6),
        );
      } catch (_) {
        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
      }

      final device = await found.future.timeout(const Duration(seconds: 7));
      await FlutterBluePlus.stopScan();
      await sub.cancel();

      if (device.remoteId.str != pump.remoteId) {
        await _upsertPump(pump.copyWith(remoteId: device.remoteId.str));
      }
      return device;
    } catch (_) {
      await FlutterBluePlus.stopScan();
      await sub.cancel();
      // Last resort: cached id (may still work if the OS remembers it).
      return BluetoothDevice.fromId(pump.remoteId);
    }
  }

  bool _scanMatchesSavedPump(ScanResult r, SavedPump pump) {
    if (r.device.remoteId.str == pump.remoteId) {
      return true;
    }
    final name = r.advertisementData.advName;
    final serial = pump.serial.toUpperCase();
    if (serial.isEmpty || serial == '----') {
      return false;
    }
    final hasSvc = r.advertisementData.serviceUuids.any(
      (u) => u == TankLinkUuids.service,
    );
    if (!name.startsWith(TankLinkUuids.deviceNamePrefix) && !hasSvc) {
      return false;
    }
    return name.toUpperCase().endsWith('-$serial');
  }

  Future<void> _refreshInfo() async {
    final info = PumpInfo.parse(await _info!.read());
    pumpProtoMajor = info.protoMajor;
    pumpProtoMinor = info.protoMinor;
    pumpHwRev = info.hwRev;
    firmware = info.firmware;
    if (info.runSeconds > 0) {
      runSeconds = info.runSeconds;
    }
    final cur = selected;
    if (cur != null &&
        (cur.deviceIdHex != info.deviceIdHex || cur.serial != info.serial)) {
      await _upsertPump(
        cur.copyWith(deviceIdHex: info.deviceIdHex, serial: info.serial),
      );
    }
  }

  void _applySettings(PumpSettings? s) {
    if (s == null) return;
    runSeconds = s.runSeconds;
    buzzerFlags = s.buzzerFlags;
    buzzerTone = s.buzzerTone;
    ledBrightness = s.ledBrightness;
    starterType = s.starterType;
    relayPulseMs = s.relayPulseMs;
  }

  bool get buzzerEnabled => (buzzerFlags & TankLinkUuids.buzzEnabled) != 0;
  bool get buzzOnButton => (buzzerFlags & TankLinkUuids.buzzOnButton) != 0;
  bool get buzzOnPump => (buzzerFlags & TankLinkUuids.buzzOnPump) != 0;
  bool get buzzOnAutoOff => (buzzerFlags & TankLinkUuids.buzzOnAutoOff) != 0;

  Future<void> _writeSettings({
    int? flags,
    int? tone,
    int? brightness,
    int? starter,
    int? pulseMs,
  }) async {
    if (_settings == null || !authed) {
      status = 'Not connected';
      notifyListeners();
      return;
    }
    final next = PumpSettings(
      buzzerFlags: flags ?? buzzerFlags,
      buzzerTone: (tone ?? buzzerTone).clamp(0, 3),
      ledBrightness: (brightness ?? ledBrightness).clamp(1, 100),
      starterType: (starter ?? starterType).clamp(0, 1),
      relayPulseMs: (pulseMs ?? relayPulseMs).clamp(
        TankLinkUuids.relayPulseMsMin,
        TankLinkUuids.relayPulseMsMax,
      ),
    );
    await _settings!.write(next.encode(), withoutResponse: false);
    _applySettings(
      PumpSettings(
        runSeconds: runSeconds,
        buzzerFlags: next.buzzerFlags,
        buzzerTone: next.buzzerTone,
        ledBrightness: next.ledBrightness,
        starterType: next.starterType,
        relayPulseMs: next.relayPulseMs,
      ),
    );
    notifyListeners();
  }

  /// Set one tank's auto-off. The pump notifies the new tank list.
  Future<void> setAutoOffMinutes(int slot, int minutes) async {
    final chr = _cmd;
    if (chr == null || !authed) {
      throw StateError('Connect to the pump first');
    }
    final m = minutes.clamp(0, TankLinkUuids.autoOffMaxMin);
    await chr.write([
      TankLinkUuids.cmdTankAutoOff,
      slot,
      m,
    ], withoutResponse: false);
    tanks = [
      for (final t in tanks) t.index == slot ? t.copyWith(autoOffMin: m) : t,
    ];
    notifyListeners();
  }

  Future<void> setLedBrightness(int percent) async {
    await _writeSettings(brightness: percent.clamp(1, 100));
  }

  /// Set one sensor's float mode. The pump notifies the new tank list.
  Future<void> setSensorMode(TankSensor sensor, int mode) async {
    final next = mode.clamp(0, TankLinkUuids.sensorModeTwo);
    final chr = _cmd;
    if (chr == null || !authed) {
      throw StateError('Connect to the pump first');
    }
    await chr.write(
      TankSensor.encodeMode(sensor.idHex, next),
      withoutResponse: false,
    );
    status = switch (next) {
      TankLinkUuids.sensorModeEmpty => 'Almost-empty sensor on',
      TankLinkUuids.sensorModeTwo => 'Two tanks',
      _ => 'Second float off',
    };
    notifyListeners();
  }

  Future<void> setStarterType(int type) async {
    await _writeSettings(starter: type.clamp(0, 1));
    status = type == TankLinkUuids.starterTwoButton
        ? 'Two-button starter'
        : 'Starter: none';
    notifyListeners();
  }

  Future<void> setStarterConfig({
    required int type,
    required int pulseMs,
  }) async {
    await _writeSettings(
      starter: type.clamp(0, 1),
      pulseMs: pulseMs.clamp(
        TankLinkUuids.relayPulseMsMin,
        TankLinkUuids.relayPulseMsMax,
      ),
    );
    status = type == TankLinkUuids.starterTwoButton
        ? 'Start and Stop · $relayPulseMs ms'
        : 'Starter: none';
    notifyListeners();
  }

  Future<void> setBuzzerSettings({
    bool? enabled,
    bool? onButton,
    bool? onPump,
    bool? onAutoOff,
    int? tone,
  }) async {
    var f = buzzerFlags;
    void bit(int mask, bool? v) {
      if (v == null) return;
      f = v ? (f | mask) : (f & ~mask);
    }

    bit(TankLinkUuids.buzzEnabled, enabled);
    bit(TankLinkUuids.buzzOnButton, onButton);
    bit(TankLinkUuids.buzzOnPump, onPump);
    bit(TankLinkUuids.buzzOnAutoOff, onAutoOff);
    await _writeSettings(flags: f, tone: tone);
    status = buzzerEnabled ? 'Buzzer updated' : 'Buzzer off';
    notifyListeners();
  }

  Future<void> testBuzzer() async {
    if (_cmd == null || !authed) return;
    await _cmd!.write([TankLinkUuids.cmdTestBeep], withoutResponse: false);
  }

  void _applyTankStatus(TankStatus? t) {
    if (t == null) return;
    _logTankStatusChanges(t);
    tankBound = t.bound;
    tankPairing = t.pairing;
    tankIdHex = t.tankIdHex;
    tankFw = t.firmware;
    tankFlags = t.flags;
    tankBatteryPct = t.batteryPct;
    tankOnline = t.online;
    final age = t.ageSec;
    _tankLastHeardAt = age == null
        ? null
        : DateTime.now().subtract(Duration(seconds: age));
    tankRssiDbm = t.rssiDbm;
    tankSnrDb = t.snrDb;
    pumpLastError = t.pumpLastError;
    tankFault = t.tankFault;
    tankHwRev = t.hwRev;
    fillInterruption = t.interruption;
    tankBleToken = t.bleToken;
    if (!tankBound) {
      tankOnline = false;
      tankFault = 0;
      _tankLastHeardAt = null;
      tankRssiDbm = null;
      tankSnrDb = null;
      tankBleToken = null;
    } else {
      // Keep online flag honest as wall-clock age advances between notifies.
      final age = tankAgeSec;
      if (age != null && age > TankLinkUuids.tankStaleSec) {
        tankOnline = false;
      }
    }
    _applySimulatedErrors();
    _ensureAgeTicker();
  }

  void _applySimulatedErrors() {
    if (!kDebugMode) return;
    if (simPumpError != null) pumpLastError = simPumpError!;
    if (simTankFault != null) tankFault = simTankFault!;
  }

  /// Debug builds only. Null leaves that code to the pump again.
  void simulateErrors({int? pump, int? tank}) {
    if (!kDebugMode) return;
    simPumpError = pump;
    simTankFault = tank;
    AppLog.w(
      'debug',
      'Simulated pump error ${pump ?? '-'}, tank code ${tank ?? '-'}',
    );
    _applySimulatedErrors();
    notifyListeners();
  }

  void _applySensors(List<TankSensor>? list) {
    if (list == null) return;
    sensors = list;
    final now = DateTime.now();
    _sensorHeardAt.clear();
    for (final s in list) {
      final age = s.ageSec;
      if (age != null) {
        _sensorHeardAt[s.index] = now.subtract(Duration(seconds: age));
      }
    }
    _ensureAgeTicker();
  }

  void _ensureAgeTicker() {
    final heard = _tankLastHeardAt != null || _sensorHeardAt.isNotEmpty;
    if (!authed || !connected || !heard) {
      _ageTicker?.cancel();
      _ageTicker = null;
      return;
    }
    _ageTicker ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (!authed ||
          !connected ||
          (_tankLastHeardAt == null && _sensorHeardAt.isEmpty)) {
        _ageTicker?.cancel();
        _ageTicker = null;
        return;
      }
      final age = tankAgeSec;
      if (age != null && age > TankLinkUuids.tankStaleSec && tankOnline) {
        tankOnline = false;
      }
      notifyListeners();
    });
  }

  Future<void> startTankPair() async {
    if (_cmd == null || !authed) {
      throw StateError('Not connected');
    }
    await _cmd!.write([TankLinkUuids.cmdTankPair], withoutResponse: false);
    tankPairing = true;
    notifyListeners();
  }

  /// Forget one tank sensor, its tanks, and their schedules.
  Future<void> unpairSensor(TankSensor sensor) async {
    final chr = _cmd;
    if (chr == null || !authed) {
      throw StateError('Not connected');
    }
    if (sensorFeedsRunningFill(sensor)) {
      throw StateError('Stop the pump before removing this sensor');
    }
    await chr.write(
      TankSensor.encodeUnpair(sensor.idHex),
      withoutResponse: false,
    );
  }

  Future<void> unpairOnDevice() async {
    if (_cmd == null || !authed) return;
    await _cmd!.write([TankLinkUuids.cmdUnpair], withoutResponse: false);
    final pump = selected;
    if (pump != null) {
      await forgetPump(pump);
    }
  }

  /// Clears BLE pairing, tank bind, and settings on the device (reboots).
  Future<void> factoryResetOnDevice() async {
    if (_cmd == null || !authed) {
      throw StateError('Not connected');
    }
    await _cmd!.write([TankLinkUuids.cmdFactoryReset], withoutResponse: false);
    final pump = selected;
    if (pump != null) {
      await forgetPump(pump);
    }
  }

  Future<void> clearPumpError() async {
    simPumpError = null;
    pumpLastError = TankLinkUuids.pumpErrNone;
    notifyListeners();
    if (_cmd == null || !authed) return;
    try {
      await _cmd!.write([TankLinkUuids.cmdClearError], withoutResponse: false);
    } catch (_) {
      /* Local clear already applied. */
    }
  }

  Future<void> dismissFillInterruption() async {
    fillInterruption = null;
    notifyListeners();
    if (_cmd == null || !authed) return;
    try {
      await _cmd!.write([
        TankLinkUuids.cmdDismissInterrupt,
      ], withoutResponse: false);
    } catch (_) {
      /* Local dismiss already applied; the pump shows it again next connect. */
    }
  }

  Future<void> startScan() async {
    scanResults.clear();
    scanning = true;
    status = 'Scanning…';
    notifyListeners();

    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      scanning = false;
      status = 'Bluetooth is off';
      notifyListeners();
      return;
    }

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName;
        final hasSvc = r.advertisementData.serviceUuids.any(
          (u) => u == TankLinkUuids.service,
        );
        final match = name.startsWith(TankLinkUuids.deviceNamePrefix) || hasSvc;
        if (!match) continue;
        final i = scanResults.indexWhere(
          (e) => e.device.remoteId == r.device.remoteId,
        );
        if (i >= 0) {
          scanResults[i] = r;
        } else {
          scanResults.add(r);
        }
      }
      notifyListeners();
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    await FlutterBluePlus.isScanning
        .where((v) => v == false)
        .first
        .timeout(const Duration(seconds: 15), onTimeout: () => false);

    scanning = false;
    status = scanResults.isEmpty
        ? 'No pumps found nearby'
        : 'Found ${scanResults.length} nearby';
    notifyListeners();
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    scanning = false;
    notifyListeners();
  }

  Future<void> claimDevice(BluetoothDevice device) async {
    status = 'Connecting…';
    notifyListeners();
    await _connectAndDiscover(device);

    status = 'Claiming…';
    notifyListeners();
    await _pair!.setNotifyValue(true);

    final completer = Completer<Uint8List>();
    await _pairNotifySub?.cancel();
    _pairNotifySub = _pair!.onValueReceived.listen((value) {
      if (value.length == TankLinkUuids.tokenLen && !completer.isCompleted) {
        completer.complete(Uint8List.fromList(value));
      }
    });

    await _pair!.write([0x01], withoutResponse: false);
    final token = await completer.future.timeout(const Duration(seconds: 8));
    final info = PumpInfo.parse(await _info!.read());
    final pump = SavedPump(
      remoteId: device.remoteId.str,
      deviceIdHex: info.deviceIdHex,
      token: token,
      serial: info.serial,
    );
    await _upsertPump(pump);

    await _auth!.write(token, withoutResponse: false);
    authed = true;
    connecting = false;
    connectFailed = false;
    await _startSession();
    notifyListeners();
  }

  /// After auth: read Info, then bind everything if the protocol matches.
  Future<void> _startSession() async {
    await _refreshInfo();
    if (protocolMismatch) {
      status = pumpNeedsNewerApp
          ? 'Update the TankLink app to use this pump'
          : 'Update the pump firmware to use this app';
      return;
    }
    await _bindControlCharacteristics();
    await _bindSchedules();
    await _bindTanks();
    final stateVal = await _state!.read();
    if (stateVal.isNotEmpty) {
      _applyPumpOn(stateVal[0] != 0);
    }
    try {
      _applySettings(PumpSettings.parse(await _settings!.read()));
    } catch (e) {
      debugPrint('settings read failed: $e');
    }
    status = 'Connected';
  }

  void _applyPumpOn(bool on) {
    pumpOn = on;
    if (on) {
      _runTicker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (pumpOn) {
          runSeconds += 1;
          notifyListeners();
        }
      });
    } else {
      _runTicker?.cancel();
      _runTicker = null;
      runSeconds = 0;
    }
  }

  Future<void> setPump(bool on) async {
    if (_cmd == null || !authed) {
      status = 'Not connected';
      notifyListeners();
      return;
    }
    if (on && tankBound && tankOnline && tankFull) {
      pumpLastError = TankLinkUuids.pumpErrTankFull;
      status = 'Tank is full';
      notifyListeners();
      return;
    }
    await _cmd!.write([on ? 1 : 0], withoutResponse: false);
    _applyPumpOn(on);
    if (on) {
      pumpLastError = TankLinkUuids.pumpErrNone;
    }
    status = on ? 'Pump running' : 'Pump stopped';
    notifyListeners();
  }

  /// Scan for [sensor] (default: the selected tank's) advertising after a
  /// button press, then BLE OTA.
  Future<void> otaUpdateTank(
    Uint8List image, {
    TankSensor? sensor,
    void Function()? onScanning,
    void Function(int done, int total)? onProgress,
    void Function()? onVerifying,
    void Function()? onRebooting,
  }) async {
    final target = sensor ?? activeSensor;
    if (target == null || !target.otaReady || target.idHex.isEmpty) {
      throw StateError('Set up the tank sensor again to allow updates');
    }
    final wantId = target.idHex.toLowerCase().replaceAll(':', '');
    final token = Uint8List.fromList(target.bleToken!);

    onScanning?.call();
    await FlutterBluePlus.stopScan();
    BluetoothDevice? tankDevice;
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName;
        // Manufacturer data: company 0xFFFF, then the 6-byte tank id.
        final id = r
            .advertisementData
            .manufacturerData[TankLinkUuids.tankMfgCompanyId];
        if (id != null && id.length == 6) {
          final hex = id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
          if (hex == wantId) {
            tankDevice = r.device;
            return;
          }
        }
        // The tank drops manufacturer data if the advert is too big, so
        // also match the TL-Tank-XXXX name suffix.
        if (name.startsWith(TankLinkUuids.tankAdvNamePrefix) &&
            wantId.length >= 4) {
          final suffix = wantId.substring(wantId.length - 4).toUpperCase();
          if (name.toUpperCase().endsWith(suffix)) {
            tankDevice = r.device;
            return;
          }
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 90),
        androidUsesFineLocation: false,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 95));
      while (tankDevice == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await FlutterBluePlus.stopScan();
      await sub.cancel();
      if (tankDevice == null) {
        throw StateError(
          'Tank not found — press the button once on the tank sensor',
        );
      }

      final device = tankDevice!;
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 20),
      );
      try {
        await device.requestMtu(512);
      } catch (_) {}
      try {
        final svc = (await device.discoverServices()).firstWhere(
          (s) => s.uuid == TankLinkUuids.service,
          orElse: () =>
              throw StateError('Tank firmware cannot be updated from the app'),
        );
        BluetoothCharacteristic chr(Guid id) => svc.characteristics.firstWhere(
          (c) => c.uuid == id,
          orElse: () =>
              throw StateError('Tank firmware cannot be updated from the app'),
        );
        await chr(TankLinkUuids.auth).write(token, withoutResponse: false);
        await uploadFirmware(
          OtaCharacteristics(
            ctrl: chr(TankLinkUuids.otaCtrl),
            data: chr(TankLinkUuids.otaData),
            status: chr(TankLinkUuids.otaStatus),
          ),
          image,
          mtu: device.mtuNow,
          onProgress: onProgress,
          onVerifying: onVerifying,
        );
        onRebooting?.call();
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        try {
          await device.disconnect();
        } catch (_) {}
      }
    } finally {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await sub.cancel();
    }
  }

  /// Push a firmware image over BLE OTA. [onProgress] reports bytes written.
  Future<void> otaUpdate(
    Uint8List image, {
    void Function(int done, int total)? onProgress,
    void Function()? onVerifying,
    void Function()? onRebooting,
  }) async {
    if (!authed || !connected) {
      throw StateError('Not connected');
    }
    if (pumpOn) {
      throw StateError('Stop the pump before updating');
    }

    await uploadFirmware(
      OtaCharacteristics(ctrl: _otaCtrl!, data: _otaData!, status: _otaStatus!),
      image,
      mtu: _device?.mtuNow ?? 23,
      onProgress: onProgress,
      onVerifying: onVerifying,
    );
    onRebooting?.call();

    // The pump reboots into the new image: wait, then reconnect.
    await Future<void>.delayed(const Duration(seconds: 2));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      try {
        await connectSelected();
        if (authed && connected) return;
      } catch (_) {}
    }
    throw StateError('Updated, but couldn’t reconnect. Tap Connect.');
  }

  Future<void> disconnect() async {
    _runTicker?.cancel();
    _runTicker = null;
    _ageTicker?.cancel();
    _ageTicker = null;
    _clockSyncTimer?.cancel();
    _clockSyncTimer = null;
    _stopBleRssiPoll();
    await _pairNotifySub?.cancel();
    await _stateNotifySub?.cancel();
    await _tankNotifySub?.cancel();
    await _schedNotifySub?.cancel();
    await _tanksNotifySub?.cancel();
    await _sensorsNotifySub?.cancel();
    await _historyNotifySub?.cancel();
    await _batteryNotifySub?.cancel();
    await _connSub?.cancel();
    _pairNotifySub = null;
    _stateNotifySub = null;
    _tankNotifySub = null;
    _schedNotifySub = null;
    _tanksNotifySub = null;
    _sensorsNotifySub = null;
    _historyNotifySub = null;
    _batteryNotifySub = null;
    _connSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _service = null;
    _info = null;
    _pair = _auth = _state = _cmd = _settings = null;
    _otaCtrl = _otaData = _otaStatus = _tank = _sched = _tanks = null;
    _sensorsChr = _historyChr = _batteryChr = null;
    fills = [];
    batteryLogs = {};
    sensors = [];
    _sensorHeardAt.clear();
    pumpClockValid = false;
    pumpRtcOk = false;
    schedules = [];
    activeSlot = 0;
    tanks = [];
    connected = false;
    authed = false;
    connecting = false;
    pumpOn = false;
    runSeconds = 0;
    tankBound = false;
    tankPairing = false;
    tankOnline = false;
    tankIdHex = '';
    tankFw = '';
    tankBleToken = null;
    tankFlags = 0;
    tankBatteryPct = 0;
    _tankLastHeardAt = null;
    tankRssiDbm = null;
    bleRssiDbm = null;
    tankSnrDb = null;
    pumpLastError = 0;
    tankFault = 0;
    fillInterruption = null;
    pumpProtoMajor = 0;
    pumpProtoMinor = 0;
    pumpHwRev = 0;
    tankHwRev = 0;
    notifyListeners();
  }

  Future<void> disconnectAndStay() async {
    await disconnect();
    connectFailed = true;
    status = 'Disconnected';
    notifyListeners();
  }

  void _logTankStatusChanges(TankStatus t) {
    if (simPumpError == null && t.pumpLastError != pumpLastError) {
      AppLog.w('pump', 'Pump error ${t.pumpLastError} (was $pumpLastError)');
    }
    final fault = t.bound ? t.tankFault : 0;
    if (simTankFault == null && fault != tankFault) {
      AppLog.w('tank', 'Tank sensor code $fault (was $tankFault)');
    }
    if (t.bound && t.online != tankOnline) {
      AppLog.i('tank', t.online ? 'Tank online' : 'Tank offline');
    }
    final i = t.interruption;
    if (i != null && fillInterruption == null) {
      AppLog.w(
        'pump',
        'Fill interrupted: reason ${i.reason}, ran ${i.ranSec}s',
      );
    }
  }

  Future<void> _connectAndDiscover(BluetoothDevice device) async {
    await stopScan();
    _device = device;
    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 15),
    );
    connected = true;

    await _connSub?.cancel();
    _connSub = device.connectionState.listen((s) {
      connected = s == BluetoothConnectionState.connected;
      AppLog.i('ble', 'Connection: ${s.name}');
      if (!connected) {
        authed = false;
        _clockSyncTimer?.cancel();
        _clockSyncTimer = null;
        _stopBleRssiPoll();
        _applyPumpOn(false);
        if (!connecting) {
          status = 'Disconnected';
          connectFailed = true;
        }
      }
      notifyListeners();
    });

    final services = await device.discoverServices();
    final svc = services.firstWhere(
      (s) => s.uuid == TankLinkUuids.service,
      orElse: () => throw StateError('TankLink service missing'),
    );
    _service = svc;
    // The frozen set (see docs/PROTOCOL.md): present on every protocol major.
    _info = _chr(TankLinkUuids.info);
    _pair = _chr(TankLinkUuids.pair);
    _auth = _chr(TankLinkUuids.auth);
    _otaCtrl = _chr(TankLinkUuids.otaCtrl);
    _otaData = _chr(TankLinkUuids.otaData);
    _otaStatus = _chr(TankLinkUuids.otaStatus);

    try {
      await device.requestMtu(512);
    } catch (_) {}
    _startBleRssiPoll();
  }

  void _startBleRssiPoll() {
    _rssiTimer?.cancel();
    _rssiTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_readBleRssi());
    });
    unawaited(_readBleRssi());
  }

  void _stopBleRssiPoll() {
    _rssiTimer?.cancel();
    _rssiTimer = null;
    bleRssiDbm = null;
  }

  Future<void> _readBleRssi() async {
    final device = _device;
    if (device == null || !connected || _rssiBusy) return;
    _rssiBusy = true;
    try {
      final rssi = await device.readRssi(timeout: 4);
      if (!connected || _device != device) return;
      if (bleRssiDbm != rssi) {
        bleRssiDbm = rssi;
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _rssiBusy = false;
    }
  }

  BluetoothService? _service;

  BluetoothCharacteristic _chr(Guid uuid) =>
      _service!.characteristics.firstWhere(
        (c) => c.uuid == uuid,
        orElse: () => throw StateError('Pump is missing a characteristic'),
      );

  /// Only called once the protocol major matches.
  Future<void> _bindControlCharacteristics() async {
    _state = _chr(TankLinkUuids.state);
    _cmd = _chr(TankLinkUuids.cmd);
    _settings = _chr(TankLinkUuids.settings);
    _tank = _chr(TankLinkUuids.tank);
    _sched = _chr(TankLinkUuids.sched);
    _tanks = _chr(TankLinkUuids.tanks);
    _sensorsChr = _chr(TankLinkUuids.sensors);
    _historyChr = _chr(TankLinkUuids.history);
    _batteryChr = _chr(TankLinkUuids.battery);

    await _state!.setNotifyValue(true);
    await _stateNotifySub?.cancel();
    _stateNotifySub = _state!.onValueReceived.listen((value) {
      if (value.isNotEmpty) {
        _applyPumpOn(value[0] != 0);
        notifyListeners();
      }
    });

    await _tankNotifySub?.cancel();
    await _tank!.setNotifyValue(true);
    _tankNotifySub = _tank!.onValueReceived.listen((value) {
      _applyTankStatus(TankStatus.parse(value));
      notifyListeners();
    });
    try {
      _applyTankStatus(TankStatus.parse(await _tank!.read()));
    } catch (_) {}
  }

  /// Push the phone's local civil time. Schedules do not run until this lands.
  Future<void> syncPumpClock() async {
    final chr = _sched;
    if (chr == null || !authed) {
      return;
    }
    await chr.write(
      ScheduleState.encodeClock(DateTime.now()),
      withoutResponse: false,
    );
    try {
      _applySchedule(ScheduleState.parse(await chr.read()));
      notifyListeners();
    } catch (_) {}
  }

  /// Replace the pump's daily fill times. Throws if the pump rejects the list.
  Future<void> replaceFillSchedules(List<FillSchedule> next) async {
    final chr = _sched;
    if (chr == null || !authed) {
      throw StateError('Schedules need a connected pump');
    }
    if (next.length > TankLinkUuids.schedMax) {
      throw StateError('Only ${TankLinkUuids.schedMax} fill times');
    }
    final sorted = [...next]
      ..sort((a, b) => a.minutesOfDay.compareTo(b.minutesOfDay));
    final seen = <int>{};
    for (final s in sorted) {
      if (s.hour < 0 || s.hour > 23 || s.minute < 0 || s.minute > 59) {
        throw StateError('Pick a valid time');
      }
      if (!seen.add(s.minutesOfDay)) {
        throw StateError('That time is already scheduled');
      }
    }
    // One tank: every fill goes to it, whatever its slot index.
    final only = tanks.length == 1 ? tanks.first.index : null;
    final toSend = [
      for (final s in sorted)
        s.copyWith(
          slot: only ?? s.slot.clamp(0, TankLinkUuids.tankSlotMax - 1),
        ),
    ];
    await chr.write(ScheduleState.encodeList(toSend), withoutResponse: false);
    schedules = toSend;
    notifyListeners();
  }

  Future<void> _bindSchedules() async {
    final chr = _sched!;
    await _schedNotifySub?.cancel();
    await chr.setNotifyValue(true);
    _schedNotifySub = chr.onValueReceived.listen((value) {
      _applySchedule(ScheduleState.parse(value));
      notifyListeners();
    });
    await syncPumpClock();
    _clockSyncTimer?.cancel();
    _clockSyncTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (authed && connected) {
        unawaited(syncPumpClock());
      }
    });
  }

  void _applySchedule(ScheduleState? st) {
    if (st == null) return;
    pumpClockValid = st.clockValid;
    pumpClockHour = st.clockHour;
    pumpClockMinute = st.clockMinute;
    schedules = st.schedules;
    pumpRtcOk = st.rtcOk;
  }

  Future<void> selectTank(int slot) async {
    final chr = _cmd;
    if (chr == null || !authed) {
      throw StateError('Connect to the pump first');
    }
    if (pumpOn && slot != activeSlot) {
      throw StateError('Stop the pump before switching tanks');
    }
    await chr.write([
      TankLinkUuids.cmdTankSelect,
      slot,
    ], withoutResponse: false);
    activeSlot = slot;
    notifyListeners();
  }

  Future<void> renameTank(int slot, String name) async {
    final chr = _cmd;
    if (chr == null || !authed) {
      throw StateError('Connect to the pump first');
    }
    final bytes = encodeTankName(name);
    if (bytes.isEmpty) {
      throw StateError('Use letters or numbers');
    }
    if (bytes.length >= TankLinkUuids.tankNameLen) {
      throw StateError('Name is too long');
    }
    await chr.write([
      TankLinkUuids.cmdTankRename,
      slot,
      ...bytes,
    ], withoutResponse: false);
  }

  Future<void> _bindTanks() async {
    final chr = _tanks!;
    await _tanksNotifySub?.cancel();
    await chr.setNotifyValue(true);
    _tanksNotifySub = chr.onValueReceived.listen((value) {
      _applyTanks(TankList.parse(value));
      notifyListeners();
    });
    try {
      _applyTanks(TankList.parse(await chr.read()));
    } catch (_) {}
    final sensorsChr = _sensorsChr!;
    await _sensorsNotifySub?.cancel();
    await sensorsChr.setNotifyValue(true);
    _sensorsNotifySub = sensorsChr.onValueReceived.listen((value) {
      _applySensors(TankSensor.parseList(value));
      notifyListeners();
    });
    try {
      _applySensors(TankSensor.parseList(await sensorsChr.read()));
    } catch (_) {}
    _historyNotifySub = await _follow(_historyChr!, _historyNotifySub, (v) {
      final list = parseFillHistory(v);
      if (list != null) fills = list;
    });
    _batteryNotifySub = await _follow(_batteryChr!, _batteryNotifySub, (v) {
      final logs = parseBatteryLog(v);
      if (logs != null) batteryLogs = logs;
    });
  }

  /// Subscribe to [chr], apply each value with [apply], and read it once.
  Future<StreamSubscription<List<int>>> _follow(
    BluetoothCharacteristic chr,
    StreamSubscription<List<int>>? old,
    void Function(List<int>) apply,
  ) async {
    await old?.cancel();
    await chr.setNotifyValue(true);
    final sub = chr.onValueReceived.listen((v) {
      apply(v);
      notifyListeners();
    });
    try {
      apply(await chr.read());
    } catch (_) {}
    return sub;
  }

  void _applyTanks(TankList? list) {
    if (list == null) return;
    activeSlot = list.activeSlot;
    tanks = list.slots;
  }

  @override
  void dispose() {
    _runTicker?.cancel();
    _ageTicker?.cancel();
    _clockSyncTimer?.cancel();
    _rssiTimer?.cancel();
    unawaited(disconnect());
    unawaited(stopScan());
    super.dispose();
  }
}
