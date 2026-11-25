import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../alerts/alert_bridge.dart';
import '../diag/app_log.dart';
import '../link/ble_link.dart';
import '../link/pump_link.dart';
import '../link/pump_finder.dart';
import '../link/wifi_link.dart';
import '../util/error_text.dart';
import '../util/format.dart';
import '../util/water_use.dart';
import 'battery_trend.dart';
import 'models.dart';
import 'ota_upload.dart';
import 'protocol.dart';
import 'tanklink_uuids.dart';

export 'models.dart';
export 'battery_trend.dart';
export 'protocol.dart'
    show
        TankSensor,
        WifiState,
        WifiStatus,
        WifiNetwork,
        PumpUpdateState,
        PumpCheckResult;

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

  /// The pump's buzzer settings; null until read.
  BuzzerConfig? buzzer;

  /// Auto-fill settings and what it is doing now; null until read.
  AutoFillInfo? autoFill;
  int ledBrightness = 70; // 1-100
  int starterType = TankLinkUuids.starterNone;
  int relayPulseMs = TankLinkUuids.relayPulseMsDefault;

  int activeSlot = 0;
  List<TankSlot> tanks = [];

  /// Paired tank sensors, up to [TankLinkUuids.sensorMax].
  List<TankSensor> sensors = [];

  /// The pump's fills (up to 200), newest first. The same on every phone.
  List<FillRecord> fills = [];

  /// Flow, power and price for the usage charts, saved on the pump.
  UsageSettings usageSettings = const UsageSettings();

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

  /// The pump's clock lost power since it started (flat clock battery).
  bool clockLostPower = false;

  /// The pump's boot id from its last Tank status (new on every start).
  int pumpBootId = 0;

  /// The clock battery banner dismissed per pump (device id), for the boot
  /// it was dismissed on. Saved on the phone; when the pump restarts it has
  /// a new boot id, so the warning comes back if the clock is still flat.
  final Map<String, int> _clockLostDismissed = {};
  static const _clockDismissedKey = 'clock_lost_dismissed_boot';

  bool get clockLostDismissed {
    final id = selected?.deviceIdHex;
    return id != null &&
        pumpBootId != 0 &&
        _clockLostDismissed[id] == pumpBootId;
  }

  /// Debug builds only: codes that replace the pump's reported ones so the
  /// error banners and reports can be tried without breaking hardware.
  int? simPumpError;
  int? simTankFault;

  /// Debug builds only: a made-up battery log (daily lows, oldest first) and
  /// percentage for every tank sensor, to try the battery trend lines.
  List<int>? simBatteryLows;
  int? simBatteryPct;

  /// Set when a fill was cut short by a power cut or restart, until dismissed.
  FillInterruption? fillInterruption;
  bool pumpClockValid = false;

  /// The DS3231 holds a trusted time, so schedules survive a restart.
  bool pumpRtcOk = false;
  int pumpClockHour = 0;
  int pumpClockMinute = 0;
  List<FillSchedule> schedules = [];
  final List<ScanResult> scanResults = [];

  /// How the phone reaches the pump right now.
  LinkKind link = LinkKind.bluetooth;
  WifiLink? _wifi;

  /// The nonce this connection signed in with, to encrypt a Wi-Fi password.
  List<int>? _authNonce;

  /// The pump's own Wi-Fi status (null until read, or before Wi-Fi exists).
  WifiStatus? wifiStatus;
  StreamSubscription<List<int>>? _wifiNotifySub;
  StreamSubscription<List<int>>? _alertNotifySub;
  StreamSubscription<List<int>>? _otaNotifySub;
  StreamSubscription<List<int>>? _settingsNotifySub;
  StreamSubscription<List<int>>? _buzzerNotifySub;
  StreamSubscription<List<int>>? _autoFillNotifySub;

  /// The pump's own update status (OtaStatus): state and bytes written. Lets the
  /// app see an update it didn't start: the pump downloading one itself, or
  /// another phone sending one.
  int otaState = TankLinkUuids.otaStIdle;
  int otaOffset = 0;
  Timer? _wifiProbeTimer;
  DateTime _skipWifiUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// An update is running: never change links in the middle of one.
  bool updating = false;

  /// The pump installs its own updates at night.
  bool autoUpdate = false;

  BluetoothDevice? _device;
  PumpChr? _info;
  BluetoothCharacteristic? _pair;
  PumpChr? _auth;
  PumpChr? _state;
  PumpChr? _cmd;
  PumpChr? _settings;
  PumpChr? _otaCtrl;
  PumpChr? _otaData;
  PumpChr? _otaStatus;
  PumpChr? _tank;
  PumpChr? _sched;
  PumpChr? _tanks;
  PumpChr? _sensorsChr;
  PumpChr? _historyChr;
  PumpChr? _batteryChr;
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

  /// The pump is installing a firmware update, whoever started it (this phone,
  /// another phone, or the pump itself). It won't start, pair or reset
  /// meanwhile, so the app doesn't offer those.
  bool get pumpUpdating {
    if (!authed || !connected) return false;
    if (wifiStatus?.update == PumpUpdateState.installing) return true;
    return otaState == TankLinkUuids.otaStReady ||
        otaState == TankLinkUuids.otaStWriting ||
        otaState == TankLinkUuids.otaStVerifyOk ||
        otaState == TankLinkUuids.otaStRebooting;
  }

  /// An update this phone isn't running itself (its own shows a dialog).
  bool get pumpUpdatingElsewhere => pumpUpdating && !updating;

  bool get canStartPump {
    if (!authed || !connected) return false;
    if (pumpUpdating) return false;
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
    _clockLostDismissed.clear();
    for (final e
        in prefs.getStringList(_clockDismissedKey) ?? const <String>[]) {
      final parts = e.split('=');
      final boot = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (boot != null) _clockLostDismissed[parts[0]] = boot;
    }

    // Saved pumps hold each pump's sign-in token: Keystore/Keychain backed.
    String? listRaw;
    try {
      listRaw = await _secure.read(key: _savedPumpsKey);
    } catch (e) {
      AppLog.w('ble', 'Saved pumps unreadable: $e');
    }
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
    // The background alert code knows the saved pumps from the start, so an
    // alert can be shown before (or without) any connection.
    unawaited(syncAlertBridge());

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
    // Signed out: retrying the same key can't work; wait for Add again.
    if (authRejected) return;
    await connectSelected();
  }

  Future<void> _persistAll() async {
    final prefs = await SharedPreferences.getInstance();
    await _secure.write(
      key: _savedPumpsKey,
      value: jsonEncode(pumps.map((p) => p.toJson()).toList()),
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
    authRejected = false;
    selectedRemoteId = pump.remoteId;
    await _persistAll();
    notifyListeners();
    await connectSelected();
  }

  /// The name is stored on the pump, so every phone shows the same one. Only
  /// the connected pump can be renamed. Throws a plain-words [StateError].
  Future<void> renamePump(SavedPump pump, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    if (utf8.encode(trimmed).length > TankLinkUuids.pumpNameMax) {
      throw StateError(
        'That name is too long. Use up to ${TankLinkUuids.pumpNameMax} characters.',
      );
    }
    if (selectedRemoteId != pump.remoteId || !authed) {
      throw StateError(
        'Connect to ${pump.name} to rename it. The name is kept on the pump.',
      );
    }
    await _cmd!.write([
      TankLinkUuids.cmdRenamePump,
      ...utf8.encode(trimmed),
    ], withoutResponse: false);
    await _upsertPump(pump.copyWith(name: trimmed), select: false);
    unawaited(syncAlertBridge());
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
    unawaited(syncAlertBridge());
    if (selected != null) {
      status = 'Select a pump';
      notifyListeners();
      await connectSelected();
    } else {
      status = 'Add a pump to get started';
      notifyListeners();
    }
  }

  /// Android often fails a BLE connect once (status 133, or a link that
  /// drops before services are read) and then succeeds right after, so a
  /// failed connect is retried [attempts] times before showing an error.
  static const _connectAttempts = 4;
  static const _connectRetryWithin = Duration(seconds: 8);

  /// The connect in progress and the pump it is for. Every caller (app
  /// start, resume, the Connect button, updates) goes through
  /// [connectSelected], and only one connect runs at a time: two at once
  /// disconnect each other.
  Future<void>? _connectInFlight;
  String? _connectInFlightFor;

  Future<void> connectSelected({int attempts = _connectAttempts}) async {
    final id = selected?.remoteId;
    final running = _connectInFlight;
    if (running != null) {
      if (_connectInFlightFor == id) return running;
      try {
        await running; // another pump: let that one finish first
      } catch (_) {}
    }
    final f = _connectSelected(attempts);
    _connectInFlight = f;
    _connectInFlightFor = id;
    try {
      await f;
    } finally {
      if (identical(_connectInFlight, f)) {
        _connectInFlight = null;
        _connectInFlightFor = null;
      }
    }
  }

  /// The pump refused this phone's saved key: it was unpaired (from any
  /// phone, or by a factory reset) and this phone must add it again.
  bool authRejected = false;

  Future<void> _connectSelected(int attempts) async {
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

    // Wi-Fi first when the pump has it, but scan for it over Bluetooth at the
    // same time, so being away from home costs no extra wait.
    final tryWifi = _wifiAllowed(pump);
    final stopScan = Completer<void>();
    final deviceFuture = _resolveDeviceForConnect(
      pump,
      cancel: stopScan.future,
    );
    Future<String?>? lookup; // mDNS, only if the saved address didn't answer
    try {
      if (tryWifi) {
        final wifi = await _openWifi(pump.lastIp!, pump.token);
        if (wifi != null) {
          // The scan keeps going until Wi-Fi is up, in case the session fails.
          if (await _startWifiSession(wifi, pump)) {
            stopScan.complete();
            return;
          }
        } else {
          lookup = PumpFinder.find(pump.deviceIdHex);
        }
      }
    } on _SignedOut {
      if (!stopScan.isCompleted) stopScan.complete();
      _showSignedOut();
      return;
    }

    try {
      final device = await deviceFuture;
      await _connectWithRetries(device, attempts);
      final tokenPump = selected ?? pump;
      try {
        _authNonce = await signInWith(_auth!, tokenPump.token);
      } catch (e) {
        AppLog.w('ble', 'Auth write failed: $e');
        await disconnect();
        connecting = false;
        connectFailed = true;
        // Only a refusal means the key is wrong; a dropped link is retryable.
        authRejected = '$e'.contains('WRITE_NOT_PERMITTED');
        status = authRejected
            ? 'This phone was signed out of the pump. Add it again.'
            : 'Couldn’t connect';
        notifyListeners();
        return;
      }
      authRejected = false;
      authed = true;
      await _startSession();
      _relaxBleConnection();
      connecting = false;
      connectFailed = false;
      notifyListeners();
    } catch (e) {
      AppLog.w('ble', 'Connect failed: $e');
      await disconnect();
      // Out of Bluetooth range but maybe on the home network at a new address.
      if (lookup != null && await _connectFoundWifi(pump, await lookup)) return;
      connecting = false;
      connectFailed = true;
      status = 'Couldn’t connect';
      notifyListeners();
    }
  }

  bool _wifiAllowed(SavedPump pump) =>
      !pump.bleOnly &&
      pump.lastIp != null &&
      !DateTime.now().isBefore(_skipWifiUntil);

  void _showSignedOut() {
    authRejected = true;
    connecting = false;
    connectFailed = true;
    status = 'This phone was signed out of the pump. Add it again.';
    notifyListeners();
  }

  /// Wi-Fi at the address mDNS found ([ip]), after Bluetooth failed.
  Future<bool> _connectFoundWifi(SavedPump pump, String? ip) async {
    if (ip == null || ip == pump.lastIp) return false;
    connecting = true;
    try {
      final wifi = await _openWifi(ip, pump.token);
      return wifi != null && await _startWifiSession(wifi, pump);
    } on _SignedOut {
      _showSignedOut();
      return true;
    }
  }

  /// Open the pump's Wi-Fi API at [ip] and sign in. Null when it doesn't
  /// answer there (off the home network, or a new address); throws
  /// [_SignedOut] when the pump doesn't know this phone.
  Future<WifiLink?> _openWifi(String ip, List<int> token) async {
    final WifiLink wifi;
    try {
      wifi = await WifiLink.connect(ip);
    } catch (e) {
      AppLog.i('wifi', 'No answer at $ip: $e');
      return null;
    }
    try {
      await wifi.signIn(token);
      return wifi;
    } on WifiRequestError catch (e) {
      wifi.close();
      if (e.status == 1) throw const _SignedOut();
      AppLog.w('wifi', 'Wi-Fi sign-in refused: ${e.status}');
      return null;
    } catch (e) {
      wifi.close();
      AppLog.w('wifi', 'Wi-Fi sign-in failed: $e');
      return null;
    }
  }

  /// Make the signed-in [wifi] link the pump's link.
  void _useWifi(WifiLink wifi) {
    _wifi = wifi;
    link = LinkKind.wifi;
    _authNonce = wifi.nonce;
    connected = true;
    authed = true;
    authRejected = false;
    unawaited(
      wifi.closed.then((why) {
        if (identical(_wifi, wifi)) _onWifiLost(why);
      }),
    );
    _info = _chr(TankLinkUuids.info);
    _auth = _chr(TankLinkUuids.auth);
    _pair = null; // Bluetooth only
    _otaCtrl = _chr(TankLinkUuids.otaCtrl);
    _otaData = _chr(TankLinkUuids.otaData);
    _otaStatus = _chr(TankLinkUuids.otaStatus);
  }

  /// Start the session over a signed-in [wifi] link. False means "use
  /// Bluetooth": the session failed and everything is closed again.
  Future<bool> _startWifiSession(WifiLink wifi, SavedPump pump) async {
    _useWifi(wifi);
    try {
      AppLog.i('wifi', 'Connected over Wi-Fi (${wifi.host})');
      if (wifi.host != pump.lastIp) {
        await _upsertPump((selected ?? pump).copyWith(lastIp: wifi.host));
      }
      await _startSession();
      connecting = false;
      connectFailed = false;
      notifyListeners();
      return true;
    } catch (e) {
      AppLog.w('wifi', 'Wi-Fi session failed, using Bluetooth: $e');
      await disconnect();
      connecting = true; // the caller carries on over Bluetooth
      return false;
    }
  }

  /// The Wi-Fi link dropped (router, phone left the network): go back to
  /// Bluetooth, which the pump keeps running alongside.
  void _onWifiLost(String why) {
    AppLog.w('wifi', 'Wi-Fi link lost: $why');
    connected = false;
    authed = false;
    _clockSyncTimer?.cancel();
    _clockSyncTimer = null;
    _applyPumpOn(false);
    status = 'Wi-Fi lost, switching to Bluetooth…';
    connectFailed = true;
    _skipWifiUntil = DateTime.now().add(const Duration(seconds: 20));
    notifyListeners();
    if (!updating) unawaited(_reconnectAfterLoss());
  }

  Future<void> _reconnectAfterLoss() async {
    await disconnect();
    await connectSelected(attempts: 2);
  }

  /// While on Bluetooth, look for the pump on Wi-Fi (soon after connecting,
  /// then every 15 s, and whenever the pump reports a new address) and move
  /// over when it answers. Never during an update.
  void _startWifiProbe() {
    _wifiProbeTimer?.cancel();
    _wifiProbeTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_probeWifi());
    });
    unawaited(_probeWifi());
  }

  bool _probing = false;

  Future<void> _probeWifi() async {
    final pump = selected;
    // The address the pump reports over Bluetooth is the current one.
    final ip = wifiStatus?.ip ?? pump?.lastIp;
    if (_probing ||
        DateTime.now().isBefore(_skipWifiUntil) ||
        pump == null ||
        pump.bleOnly ||
        ip == null ||
        link != LinkKind.bluetooth ||
        !ready ||
        updating) {
      return;
    }
    _probing = true;
    try {
      final WifiLink? wifi;
      try {
        wifi = await _openWifi(ip, pump.token);
      } on _SignedOut {
        return; // Bluetooth accepted this phone; stay there
      }
      if (wifi == null) return;
      if (link != LinkKind.bluetooth ||
          !ready ||
          updating ||
          selected?.remoteId != pump.remoteId) {
        wifi.close();
        return;
      }
      await _moveToWifi(wifi, pump);
    } finally {
      _probing = false;
    }
  }

  /// Move a running Bluetooth session to [wifi] without a disconnect: the
  /// screens keep their values while everything is bound again over Wi-Fi,
  /// then Bluetooth is closed.
  Future<void> _moveToWifi(WifiLink wifi, SavedPump pump) async {
    AppLog.i('wifi', 'Pump reachable over Wi-Fi (${wifi.host}): switching');
    final device = _device;
    // Bluetooth going down is no longer news.
    await _connSub?.cancel();
    _connSub = null;
    await _pairNotifySub?.cancel();
    _pairNotifySub = null;
    _stopBleRssiPoll();
    _wifiProbeTimer?.cancel();
    _wifiProbeTimer = null;
    _skipWifiUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _useWifi(wifi);
    try {
      if (wifi.host != pump.lastIp) {
        await _upsertPump(
          (selected ?? pump).copyWith(lastIp: wifi.host),
          select: false,
        );
      }
      await _startSession(); // replaces every subscription
    } catch (e) {
      AppLog.w('wifi', 'Move to Wi-Fi failed, reconnecting: $e');
      _device = device; // so disconnect() closes Bluetooth too
      await disconnect();
      await connectSelected(attempts: 2);
      return;
    }
    _device = null;
    _service = null;
    notifyListeners();
    try {
      await device?.disconnect();
    } catch (e) {
      AppLog.w('ble', 'Bluetooth close after the move failed: $e');
    }
  }

  /// Follow the pump's update status, so an update started elsewhere is seen.
  Future<void> _bindOtaStatus() async {
    _otaNotifySub = await _follow(_otaStatus!, _otaNotifySub, (v) {
      // state(1) error(1) offset(u32)
      otaState = v[0];
      otaOffset = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
    });
  }

  /// Alerts: keep the pump's alert key (the background scan needs it to know
  /// an alert is really from this pump), tell Kotlin about the pump, and follow
  /// the pump's alert log, which also catches up on alerts missed while away.
  Future<void> _bindAlerts() async {
    final key = Uint8List.fromList(await _chr(TankLinkUuids.alertKey).read());
    final cur = selected!;
    if (cur.alertKey == null || !listEquals(cur.alertKey, key)) {
      await _upsertPump(cur.copyWith(alertKey: key), select: false);
    }
    await syncAlertBridge();
    _alertNotifySub = await _follow(
      _chr(TankLinkUuids.alertLog),
      _alertNotifySub,
      (v) => unawaited(_showAlerts(parseAlertLog(v))),
    );
  }

  /// Give each alert to the Android notifier, oldest first. It shows an alert
  /// once, whichever way it arrived, and skips ones it has shown.
  Future<void> _showAlerts(List<PumpAlert> alerts) async {
    final id = selected?.deviceIdHex;
    if (id == null) return;
    _noticeFromAlerts(alerts);
    for (final a in alerts.reversed) {
      if ((a.ageMin ?? 0) > 24 * 60) continue;
      await AlertBridge.showAlert(id.toLowerCase(), a.seq, a.type, a.arg);
    }
  }

  /// A message about something that just happened at the pump, shown on the
  /// home screen until dismissed (null = none).
  String? pumpNotice;

  /// The newest alert number already looked at in this session. The first log
  /// read after connecting only sets it: those alerts are old news.
  int? _noticeSeq;

  /// Short ids of every sensor seen this session, by index. A removed sensor is
  /// gone from the list by the time its alert arrives.
  final Map<int, String> _sensorShortIds = {};

  void _noticeFromAlerts(List<PumpAlert> alerts) {
    if (alerts.isEmpty) return;
    final seen = _noticeSeq;
    _noticeSeq = alerts.first.seq; // newest first
    if (seen == null) return;
    for (final a in alerts.reversed) {
      final ahead = (a.seq - seen) & 0xFF;
      if (ahead < 1 || ahead > 127) continue;
      if (a.type == TankLinkUuids.alertSensorRemoved) {
        final short = _sensorShortIds[a.arg & 3];
        pumpNotice =
            '${short == null ? 'A tank sensor' : 'Tank sensor $short'} was '
            'removed. Its tank went into pairing mode, so the pump dropped it. '
            'Pair it again if this wasn’t you.';
        notifyListeners();
      }
    }
  }

  void dismissNotice() {
    if (pumpNotice == null) return;
    pumpNotice = null;
    notifyListeners();
  }

  /// Tell the Android alert code which pumps to recognise, and their names.
  Future<void> syncAlertBridge() async {
    String hex(List<int> b) =>
        b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final list = <Map<String, Object?>>[];
    for (final p in pumps) {
      final key = p.alertKey;
      if (key == null || key.length != 16) continue;
      final isCurrent = p.remoteId == selected?.remoteId;
      list.add({
        'id': p.deviceIdHex.toLowerCase(),
        'mac': p.remoteId,
        'name': p.name,
        'key': hex(key),
        // Flow lets the notification say "about 480 litres" (known for the
        // connected pump; Kotlin keeps the last one for the others).
        if (isCurrent && usageSettings.flowLpm != null)
          'flow': usageSettings.flowLpm,
        // Names are known for the pump we are connected to.
        'tanks': [
          for (var i = 0; i < TankLinkUuids.tankSlotMax; i++)
            isCurrent ? tankNameFor(i) : 'Tank ${i + 1}',
        ],
        'sensors': [
          for (var i = 0; i < TankLinkUuids.sensorMax; i++)
            isCurrent && sensorAt(i) != null
                ? 'Tank sensor ${sensorAt(i)!.shortId}'
                : 'Tank sensor ${i + 1}',
        ],
      });
    }
    await AlertBridge.syncPumps(list);
  }

  /// Raise a test alert on the pump: it shows up like a real one.
  Future<void> sendTestAlert() async {
    if (!authed) throw StateError('Not connected');
    await _cmd!.write([TankLinkUuids.cmdTestAlert], withoutResponse: false);
  }

  /// Follow the pump's own Wi-Fi status and remember its address.
  Future<void> _bindWifi() async {
    _wifiNotifySub = await _follow(
      _chr(TankLinkUuids.wifi),
      _wifiNotifySub,
      (v) => _applyWifi(WifiStatus.parse(v)),
    );
  }

  void _applyWifi(WifiStatus? st) {
    if (st == null) return;
    final newIp = st.ip != null && st.ip != wifiStatus?.ip;
    wifiStatus = st;
    // On Bluetooth with the session up (the probe timer runs): try it now.
    if (newIp && _wifiProbeTimer != null) unawaited(_probeWifi());
    final cur = selected;
    if (cur != null && st.ip != null && cur.lastIp != st.ip) {
      unawaited(_upsertPump(cur.copyWith(lastIp: st.ip), select: false));
    }
  }

  /// "Connect over: Automatic / Bluetooth only" for the selected pump.
  Future<void> setBleOnly(bool value) async {
    final pump = selected;
    if (pump == null || pump.bleOnly == value) return;
    await _upsertPump(pump.copyWith(bleOnly: value), select: false);
    if (value && link == LinkKind.wifi) {
      await disconnect();
      await connectSelected();
    }
  }

  /// Wi-Fi write helper: [bytes] to the Wifi characteristic.
  Future<void> _wifiWrite(List<int> bytes) async {
    if (!authed) throw StateError('Not connected');
    await _chr(TankLinkUuids.wifi).write(bytes, withoutResponse: false);
  }

  /// Ask the pump to scan, wait for it, and return the networks it heard.
  Future<List<WifiNetwork>> wifiScan() async {
    await _wifiWrite(WifiCommands.scan());
    final chr = _chr(TankLinkUuids.wifi);
    final nets = <WifiNetwork>[];
    try {
      for (var tries = 0; tries < 12; tries++) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await _wifiWrite(WifiCommands.scanPage(0));
        final first = WifiScanPage.parse(await chr.read());
        if (first == null || first.scanning) continue;
        nets.addAll(first.networks);
        for (var page = 1; nets.length < first.total; page++) {
          await _wifiWrite(WifiCommands.scanPage(page));
          final more = WifiScanPage.parse(await chr.read());
          if (more == null || more.networks.isEmpty) break;
          nets.addAll(more.networks);
        }
        break;
      }
    } finally {
      await _wifiWrite(WifiCommands.status()); // later reads are status again
    }
    return nets;
  }

  /// Give the pump a network. The password travels encrypted.
  Future<void> wifiSet(String ssid, String password) async {
    final pump = selected;
    final nonce = _authNonce;
    if (pump == null || nonce == null) throw StateError('Not connected');
    await _wifiWrite(WifiCommands.set(ssid, password, pump.token, nonce));
  }

  Future<void> wifiForget() async {
    await _wifiWrite(WifiCommands.forget());
    final pump = selected;
    if (pump != null && pump.lastIp != null) {
      await _upsertPump(pump.copyWith(clearLastIp: true), select: false);
    }
  }

  /// Use Bluetooth for the next while (an update the user chose to send that
  /// way, even though Wi-Fi works): drops the Wi-Fi link and reconnects.
  Future<void> forceBluetooth() async {
    _skipWifiUntil = DateTime.now().add(const Duration(minutes: 10));
    if (link == LinkKind.wifi || !connected) {
      await disconnect();
      await connectSelected();
    }
  }

  /// Ask the pump to look for a firmware update now and wait for its answer.
  /// Throws a plain-words [StateError] if the pump won't or can't.
  Future<PumpCheckResult> pumpCheckUpdate() async {
    if (!authed) throw StateError('Not connected');
    if (pumpOn) {
      throw StateError('The pump is running. Check again when it has stopped.');
    }
    if (pumpUpdating) {
      throw StateError('The pump is updating.');
    }
    await _cmd!.write([TankLinkUuids.cmdUpdateCheck], withoutResponse: false);
    // The pump answers through its Wi-Fi status: "checking", then a result.
    var sawChecking = false;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final w = WifiStatus.parse(await _chr(TankLinkUuids.wifi).read());
      if (w == null) continue;
      _applyWifi(w);
      if (w.update == PumpUpdateState.checking) sawChecking = true;
      if (sawChecking && w.update != PumpUpdateState.checking) return w.check;
    }
    throw StateError('The pump did not answer. Try again.');
  }

  /// Have the pump download and install the update it found.
  Future<void> pumpInstallUpdate() async {
    if (!authed) throw StateError('Not connected');
    if (pumpOn) throw StateError('Stop the pump before updating');
    await _cmd!.write([TankLinkUuids.cmdUpdateInstall], withoutResponse: false);
  }

  Future<void> dismissOvernightUpdate() async {
    if (!authed) return;
    await _cmd!.write([TankLinkUuids.cmdUpdateDismiss], withoutResponse: false);
  }

  /// Find the saved pump via a short scan (required when another central is
  /// already connected and Android's address cache is cold).
  ///
  /// [cancel] completing stops the scan early (the pump answered on Wi-Fi).
  Future<BluetoothDevice> _resolveDeviceForConnect(
    SavedPump pump, {
    Future<void>? cancel,
  }) async {
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

      final device = await Future.any([
        found.future,
        if (cancel != null)
          cancel.then<BluetoothDevice>((_) => throw const _ScanCancelled()),
      ]).timeout(const Duration(seconds: 7));
      await FlutterBluePlus.stopScan();
      await sub.cancel();

      if (device.remoteId.str != pump.remoteId) {
        // Same pump, new Bluetooth address: replace the entry, don't add one.
        final i = pumps.indexWhere((p) => p.remoteId == pump.remoteId);
        if (i >= 0) pumps.removeAt(i);
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
    ledBrightness = s.ledBrightness;
    starterType = s.starterType;
    relayPulseMs = s.relayPulseMs;
    usageSettings = s.usage;
    autoUpdate = s.autoUpdate;
    // The pump's name is the one every phone shows: take it when it differs.
    final cur = selected;
    if (s.name.isNotEmpty && cur != null && cur.name != s.name) {
      unawaited(
        _upsertPump(
          cur.copyWith(name: s.name),
          select: false,
        ).then((_) => syncAlertBridge()),
      );
    }
  }

  Future<void> _writeSettings({
    int? brightness,
    int? starter,
    int? pulseMs,
    bool? autoUpdate,
  }) async {
    if (_settings == null || !authed) {
      throw StateError('Connect to the pump first');
    }
    final next = PumpSettings(
      ledBrightness: (brightness ?? ledBrightness).clamp(1, 100),
      starterType: starter ?? starterType,
      relayPulseMs: (pulseMs ?? relayPulseMs).clamp(
        TankLinkUuids.relayPulseMsMin,
        TankLinkUuids.relayPulseMsMax,
      ),
      autoUpdate: autoUpdate ?? this.autoUpdate,
    );
    await _settings!.write(next.encode(), withoutResponse: false);
    _applySettings(
      PumpSettings(
        runSeconds: runSeconds,
        ledBrightness: next.ledBrightness,
        starterType: next.starterType,
        relayPulseMs: next.relayPulseMs,
        usage: usageSettings,
        autoUpdate: next.autoUpdate,
      ),
    );
    notifyListeners();
  }

  /// "Install pump updates automatically" (needs Wi-Fi on the pump).
  Future<void> setAutoUpdate(bool on) => _writeSettings(autoUpdate: on);

  /// Whether [slot] can fill by itself: it has a tank sensor.
  bool canAutoFill(int slot) {
    final t = slotAt(slot);
    return t != null && sensorForSlot(t) != null;
  }

  /// Whether [slot] has an almost-empty float (almost-empty mode, pin-1
  /// tank). Without one, auto-fill tops the tank up when it drops below the
  /// full float.
  bool hasEmptyFloat(int slot) {
    final t = slotAt(slot);
    if (t == null || t.sensor != 0) return false;
    return sensorForSlot(t)?.mode == TankLinkUuids.sensorModeEmpty;
  }

  /// The tank with auto-fill on (one per pump), or null.
  TankSlot? get autoFillTank {
    for (final t in tanks) {
      if (t.autoFill) return t;
    }
    return null;
  }

  /// Turn auto-fill on or off for one tank. On moves it from any other tank.
  /// The pump notifies the tank list.
  Future<void> setAutoFill(int slot, bool on) async {
    final chr = _cmd;
    if (chr == null || !authed) {
      throw StateError('Connect to the pump first');
    }
    if (on && !canAutoFill(slot)) {
      throw StateError('This tank needs a tank sensor first');
    }
    await chr.write([
      TankLinkUuids.cmdTankAutoFill,
      slot,
      on ? 1 : 0,
    ], withoutResponse: false);
    tanks = [
      for (final t in tanks)
        t.index == slot
            ? t.copyWith(autoFill: on)
            : (on ? t.copyWith(autoFill: false) : t),
    ];
    AppLog.i('pump', 'Auto-fill ${on ? 'on' : 'off'} for slot $slot');
    notifyListeners();
  }

  /// Debug builds only: show made-up fills on the usage screen. Nothing is
  /// saved; the real fills come back when it is turned off.
  bool simUsage = false;
  List<FillRecord> _simFills = [];

  /// Fills the usage screen shows: the phone's archive, or sample data.
  List<FillRecord> get usageFills => simUsage ? _simFills : fills;

  /// Settings the usage screen draws with. With sample data, flow and price
  /// the user hasn't set are filled in so every chart has something to show.
  UsageSettings get usageSettingsShown {
    final s = usageSettings;
    if (!simUsage) return s;
    return s.copyWith(
      flowLpm: s.hasFlow ? null : () => sampleUsageSettings.flowLpm,
      pricePerKwh: s.hasPrice ? null : () => sampleUsageSettings.pricePerKwh,
    );
  }

  void simulateUsage(bool on) {
    if (!kDebugMode) return;
    simUsage = on;
    _simFills = on
        ? sampleFills(
            now: DateTime.now(),
            slots: [for (final t in tanks) t.index],
          )
        : [];
    AppLog.w('debug', 'Sample usage data ${on ? 'on' : 'off'}');
    notifyListeners();
  }

  /// Save flow, power and price on the pump, for every phone.
  Future<void> setUsageSettings(UsageSettings s) async {
    final chr = _cmd;
    if (chr == null || !authed) {
      throw StateError('Connect to the pump first');
    }
    await chr.write(encodeUsage(s), withoutResponse: false);
    usageSettings = s;
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

  Future<void> setStarterConfig({
    required int type,
    required int pulseMs,
  }) async {
    // A new starter type stops the motor with the old one first; the pump
    // refuses it mid-fill, so don't send it.
    if (pumpOn && type != starterType) {
      throw StateError('Stop the pump before changing the starter');
    }
    await _writeSettings(
      starter: type,
      pulseMs: pulseMs.clamp(
        TankLinkUuids.relayPulseMsMin,
        TankLinkUuids.relayPulseMsMax,
      ),
    );
    status = starterLabel(type, relayPulseMs);
    notifyListeners();
  }

  /// Save [next] as the pump's buzzer settings. The pump notifies them back.
  Future<void> setBuzzer(BuzzerConfig next) async {
    if (!authed || !connected) throw StateError('Connect to the pump first');
    await _chr(TankLinkUuids.buzzer)
        .write(next.encode(), withoutResponse: false);
    buzzer = next;
    notifyListeners();
  }

  /// Play [sound] on the pump now, whatever the settings.
  Future<void> testSound(int sound) async {
    if (_cmd == null || !authed) throw StateError('Connect to the pump first');
    await _cmd!.write([
      TankLinkUuids.cmdTestBeep,
      sound,
    ], withoutResponse: false);
  }

  /// Save auto-fill's pump-wide settings. The pump notifies them back, with
  /// the state they lead to.
  Future<void> setAutoFillConfig({
    required bool limitTimes,
    required bool stopAtEnd,
    required int gapMin,
    required List<DayWindow> windows,
  }) async {
    if (!authed || !connected) throw StateError('Connect to the pump first');
    await _chr(TankLinkUuids.autoFill).write(
      AutoFillInfo.encodeConfig(
        limitTimes: limitTimes,
        stopAtEnd: stopAtEnd,
        gapMin: gapMin,
        windows: windows,
      ),
      withoutResponse: false,
    );
    AppLog.i('pump', 'Auto-fill settings saved');
  }

  /// Watch the selected tank from now on: fill if it is low, and clear a pause.
  Future<void> armAutoFill() async {
    if (!authed || !connected) throw StateError('Connect to the pump first');
    await _chr(TankLinkUuids.autoFill)
        .write([TankLinkUuids.autoFillOpArm], withoutResponse: false);
    AppLog.i('pump', 'Auto-fill armed');
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
    clockLostPower = t.clockLostPower;
    pumpBootId = t.pumpBootId;
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
    if (simBatteryPct != null) tankBatteryPct = simBatteryPct!;
    final lows = simBatteryLows;
    if (lows != null) {
      final today = DateTime.now().millisecondsSinceEpoch ~/ 86400000;
      final days = [
        for (var i = 0; i < lows.length; i++)
          BatteryDay(
            day: today - (lows.length - 1 - i),
            minPct: lows[i],
            maxPct: (lows[i] + 15).clamp(0, 100),
          ),
      ];
      // Every sensor slot (a pump pairs up to 4).
      batteryLogs = {for (var i = 0; i < 4; i++) i: days};
    }
  }

  /// Debug builds only. Null lows put the pump's real battery log back
  /// (from its next battery notify or reconnect).
  void simulateBattery({List<int>? lows, int? pct}) {
    if (!kDebugMode) return;
    simBatteryLows = lows;
    simBatteryPct = pct;
    AppLog.w('debug', 'Simulated battery ${pct ?? '-'}% lows ${lows ?? '-'}');
    if (lows == null) batteryLogs = {};
    _applySimulatedErrors();
    notifyListeners();
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
    for (final s in list) {
      _sensorShortIds[s.index] = s.shortId;
    }
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

  /// Cancel: close the pump's tank-pair window, so it stops listening and its
  /// light goes back to standby. Safe to call when it is already closed.
  Future<void> stopTankPair() async {
    final chr = _cmd;
    tankPairing = false;
    notifyListeners();
    if (chr == null || !authed) return;
    try {
      await chr.write([TankLinkUuids.cmdTankPairStop], withoutResponse: false);
    } catch (e) {
      // The window still closes by itself after its timeout.
      AppLog.w('tank', 'Stop tank pairing failed: $e');
    }
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

  void dismissClockLost() {
    final id = selected?.deviceIdHex;
    if (id == null || pumpBootId == 0) return;
    _clockLostDismissed[id] = pumpBootId;
    notifyListeners();
    unawaited(_saveClockDismissed());
  }

  Future<void> _saveClockDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_clockDismissedKey, [
      for (final e in _clockLostDismissed.entries) '${e.key}=${e.value}',
    ]);
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

  /// The pump can open its phone pairing window on command (minor 2+).
  bool get canControlPairing =>
      authed && pumpProtoMinor >= TankLinkUuids.pairingControlMinor;

  /// Open the pump's phone pairing window so another phone can add it.
  /// The window switches the pump off, so it is refused while it runs.
  Future<void> openPhonePairing() async {
    final chr = _cmd;
    if (chr == null || !authed) {
      throw StateError('Connect to the pump first');
    }
    if (pumpOn) {
      throw StateError('Stop the pump first');
    }
    await chr.write([TankLinkUuids.cmdPairingOpen], withoutResponse: false);
    AppLog.i('pump', 'Phone pairing opened from the app');
  }

  /// Sign out every other phone: they keep nothing that works and must be
  /// added again. This phone stays signed in.
  Future<void> forgetOtherPhones() async {
    final chr = _cmd;
    if (chr == null || !authed) {
      throw StateError('Connect to the pump first');
    }
    await chr.write([
      TankLinkUuids.cmdForgetOtherPhones,
    ], withoutResponse: false);
    AppLog.i('pump', 'Signed out the other phones');
  }

  Future<void> closePhonePairing() async {
    final chr = _cmd;
    if (chr == null || !authed) return;
    try {
      await chr.write([TankLinkUuids.cmdPairingClose], withoutResponse: false);
      AppLog.i('pump', 'Phone pairing closed from the app');
    } catch (e) {
      AppLog.w('pump', 'Close pairing failed: $e');
    }
  }

  /// Whether the connected pump's phone pairing window is open, from Info.
  Future<bool> readPairingOpen() async {
    final chr = _info;
    if (chr == null || !connected) return false;
    return PumpInfo.parse(await chr.read()).pairingOpen;
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

  /// Scan for pumps. [continuous] keeps every advertisement coming, so a
  /// pump's pairing state (in its advertising) updates while you watch.
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 12),
    bool continuous = false,
  }) async {
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

    await FlutterBluePlus.startScan(
      timeout: timeout,
      continuousUpdates: continuous,
    );
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

  /// Claim a pump whose pairing window is open. On failure the link is
  /// closed again, so a retry starts clean.
  Future<void> claimDevice(BluetoothDevice device) async {
    try {
      await _claimDevice(device);
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  Future<void> _claimDevice(BluetoothDevice device) async {
    status = 'Connecting…';
    notifyListeners();
    await _connectWithRetries(device, _connectAttempts);

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

    try {
      await _pair!.write([0x01], withoutResponse: false);
    } catch (e) {
      // The pump has keys for as many phones as it can hold.
      if ('$e'.contains('INSUFFICIENT_RESOURCES')) {
        throw StateError(
          'This pump already has 8 phones. On a phone that has it, '
          'use Sign out other phones, then try again.',
        );
      }
      rethrow;
    }
    final token = await completer.future.timeout(const Duration(seconds: 8));
    final info = PumpInfo.parse(await _info!.read());
    final pump = SavedPump(
      remoteId: device.remoteId.str,
      deviceIdHex: info.deviceIdHex,
      token: token,
      serial: info.serial,
    );
    await _upsertPump(pump);

    _authNonce = await signInWith(_auth!, token);
    authed = true;
    authRejected = false;
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
    // Settings are followed, not read once: another phone renaming the pump or
    // changing a setting shows up here.
    _settingsNotifySub = await _follow(
      _settings!,
      _settingsNotifySub,
      (v) => _applySettings(PumpSettings.parse(v)),
    );
    _buzzerNotifySub = await _follow(
      _chr(TankLinkUuids.buzzer),
      _buzzerNotifySub,
      (v) => buzzer = BuzzerConfig.parse(v),
    );
    _autoFillNotifySub = await _follow(
      _chr(TankLinkUuids.autoFill),
      _autoFillNotifySub,
      (v) => autoFill = AutoFillInfo.parse(v),
    );
    await _bindWifi();
    await _bindOtaStatus();
    await _bindAlerts();
    if (link == LinkKind.bluetooth) _startWifiProbe();
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
    if (on && pumpUpdating) {
      // The pump would refuse; don't send it, and say why.
      status = 'Pump is updating. Starting is paused.';
      notifyListeners();
      return;
    }
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
      AppLog.i('tank', 'Update: tank found, connecting');
      // Until the first data is sent, a dropped link means the tank's
      // 10 s update window ran out (older tank firmware closes it even with
      // a phone connected) and the tank went back to sleep.
      var sent = 0;
      Never asleep(Object e) {
        AppLog.w('tank', 'Update: link lost before the transfer: $e');
        throw StateError(
          'The tank went back to sleep before the update started. '
          'Press its button once and tap Try again straight away.',
        );
      }

      try {
        await device.connect(
          license: License.nonprofit,
          timeout: const Duration(seconds: 20),
        );
      } catch (e) {
        asleep(e);
      }
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
        AppLog.i(
          'tank',
          'Update: connected (MTU ${device.mtuNow}), signing in',
        );
        try {
          await signInWith(BleChr(chr(TankLinkUuids.auth)), token);
        } on StateError {
          rethrow;
        } catch (e) {
          asleep(e);
        }
        AppLog.i('tank', 'Update: signed in, sending ${image.length} bytes');
        try {
          await uploadFirmware(
            OtaCharacteristics(
              ctrl: BleChr(chr(TankLinkUuids.otaCtrl)),
              data: BleChr(chr(TankLinkUuids.otaData)),
              status: BleChr(chr(TankLinkUuids.otaStatus)),
            ),
            image,
            mtu: device.mtuNow,
            onProgress: (d, t) {
              sent = d;
              onProgress?.call(d, t);
            },
            onVerifying: onVerifying,
          );
        } catch (e) {
          if (sent == 0) asleep(e);
          AppLog.w(
            'tank',
            'Update: stopped at $sent of ${image.length} bytes: $e',
          );
          rethrow;
        }
        AppLog.i('tank', 'Update: image checked, tank restarting');
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

  Future<void> otaUpdate(
    Uint8List image, {
    void Function(int done, int total)? onProgress,
    void Function()? onVerifying,
    void Function()? onRebooting,
  }) async {
    // Stays set through the reconnect after the restart, so the dropped link
    // isn't answered by a second reconnect.
    updating = true;
    try {
      await _otaUpdate(
        image,
        onProgress: onProgress,
        onVerifying: onVerifying,
        onRebooting: onRebooting,
      );
    } finally {
      updating = false;
    }
  }

  /// Push a firmware image to the pump, over whichever link is open (Wi-Fi
  /// is much faster). [onProgress] reports bytes written.
  Future<void> _otaUpdate(
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
      // Over Wi-Fi the chunks are big: much faster than Bluetooth.
      chunkSize: _wifi != null ? 2048 : null,
      onProgress: onProgress,
      onVerifying: onVerifying,
    );
    onRebooting?.call();
    await _reconnectAfterRestart();
  }

  /// The pump reboots into the new image: wait, then reconnect.
  Future<void> _reconnectAfterRestart() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      try {
        // One attempt each: this loop already retries while the pump boots.
        await connectSelected(attempts: 1);
        if (authed && connected) return;
      } catch (_) {}
    }
    throw StateError('Updated, but couldn’t reconnect. Tap Connect.');
  }

  /// The pump downloads and installs the update it found (over its own
  /// Wi-Fi), and the phone follows OtaStatus. [onProgress] gets the bytes
  /// written so far.
  Future<void> pumpDownloadsUpdate({
    required void Function(int offset) onProgress,
    void Function()? onVerifying,
    void Function()? onRebooting,
  }) async {
    if (!authed || _otaStatus == null) throw StateError('Not connected');
    updating = true;
    final versionBefore = firmware;
    // Set once the pump is clearly past the download: from then on a dropped
    // link means it is restarting into the new image, not that it failed.
    var pastDownload = false;
    StreamSubscription<List<int>>? sub;
    Timer? watch;
    try {
      final status = _otaStatus!;
      await status.setNotifyValue(true);
      final done = Completer<void>();
      sub = status.onValueReceived.listen((v) {
        if (v.length < 2 || done.isCompleted) return;
        if (v[1] != 0) {
          done.completeError(
            StateError('The pump refused the update: ${otaErrorText(v[1])}'),
          );
        } else if (v[0] == TankLinkUuids.otaStWriting && v.length >= 6) {
          final offset = v[2] | (v[3] << 8) | (v[4] << 16) | (v[5] << 24);
          if (offset > 0) pastDownload = true;
          onProgress(offset);
        } else if (v[0] == TankLinkUuids.otaStVerifyOk) {
          pastDownload = true;
          onVerifying?.call();
        } else if (v[0] == TankLinkUuids.otaStRebooting) {
          pastDownload = true;
          done.complete();
        }
      });
      await pumpInstallUpdate();

      // If the pump never starts, or its download fails, its Wi-Fi status
      // says so: "installing" shows up and then goes away without a restart.
      final started = DateTime.now();
      var sawInstalling = false;
      watch = Timer.periodic(const Duration(seconds: 1), (_) {
        if (done.isCompleted) return;
        if (!connected) {
          // The pump restarts as soon as it has installed, often before its
          // last status notification gets through.
          // If it didn't install, the version check after reconnecting says so.
          if (pastDownload || sawInstalling) done.complete();
          return;
        }
        final u = wifiStatus?.update;
        if (u == PumpUpdateState.installing) sawInstalling = true;
        if (sawInstalling && u != PumpUpdateState.installing) {
          done.completeError(
            StateError(
              'The pump couldn’t reach the download server. Try again, or '
              'send the update from this phone.',
            ),
          );
        } else if (!sawInstalling &&
            DateTime.now().difference(started) > const Duration(seconds: 30)) {
          done.completeError(StateError('The pump didn’t start the download.'));
        }
      });
      await done.future.timeout(const Duration(minutes: 8));
      onRebooting?.call();
      await _reconnectAfterRestart();
      // Back, but still on the old version: the restart wasn't an update.
      if (versionBefore.isNotEmpty && firmware == versionBefore) {
        throw StateError(
          'The pump restarted but is still on version $firmware. Try again.',
        );
      }
    } finally {
      watch?.cancel();
      await sub?.cancel();
      updating = false;
    }
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
    await _wifiNotifySub?.cancel();
    _wifiNotifySub = null;
    await _alertNotifySub?.cancel();
    _alertNotifySub = null;
    await _otaNotifySub?.cancel();
    _otaNotifySub = null;
    await _settingsNotifySub?.cancel();
    _settingsNotifySub = null;
    await _buzzerNotifySub?.cancel();
    _buzzerNotifySub = null;
    await _autoFillNotifySub?.cancel();
    _autoFillNotifySub = null;
    buzzer = null;
    autoFill = null;
    otaState = TankLinkUuids.otaStIdle;
    otaOffset = 0;
    pumpNotice = null;
    _noticeSeq = null;
    _sensorShortIds.clear();
    _wifiProbeTimer?.cancel();
    _wifiProbeTimer = null;
    final wifi = _wifi;
    _wifi = null; // before close, so the closed handler sees a deliberate end
    wifi?.close();
    wifiStatus = null;
    link = LinkKind.bluetooth;
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

  /// [_connectAndDiscover] with the retries described at [_connectAttempts].
  /// Used for saved pumps and when adding a new one.
  Future<void> _connectWithRetries(BluetoothDevice device, int attempts) async {
    for (var attempt = 1; ; attempt++) {
      final took = Stopwatch()..start();
      try {
        await _connectAndDiscover(device);
        return;
      } catch (e) {
        // A slow failure is a timeout: the pump is off or out of range,
        // and trying again only keeps the user waiting.
        if (attempt >= attempts || took.elapsed > _connectRetryWithin) {
          rethrow;
        }
        AppLog.w('ble', 'Connect attempt $attempt of $attempts failed: $e');
        final wasConnecting = connecting;
        await disconnect();
        connecting = wasConnecting; // disconnect() clears it
        notifyListeners();
        // flutter_blue_plus also waits 2 s after a disconnect on Android.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  Future<void> _connectAndDiscover(BluetoothDevice device) async {
    final wasScanning = scanning || FlutterBluePlus.isScanningNow;
    await stopScan();
    // Connecting the moment a scan stops often fails on Android (133).
    if (wasScanning) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    _device = device;
    link = LinkKind.bluetooth;
    _wifi = null;
    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 15),
    );
    connected = true;
    // A short connection interval while the session is set up: about 30
    // reads and subscriptions, each a round trip.
    if (Platform.isAndroid) {
      await device.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
    }

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
    _pair = _service!.characteristics.firstWhere(
      (c) => c.uuid == TankLinkUuids.pair,
      orElse: () => throw StateError('Pump is missing a characteristic'),
    );
    _auth = _chr(TankLinkUuids.auth);
    _otaCtrl = _chr(TankLinkUuids.otaCtrl);
    _otaData = _chr(TankLinkUuids.otaData);
    _otaStatus = _chr(TankLinkUuids.otaStatus);

    // connect() already asked for a 512-byte MTU.
    _startBleRssiPoll();
  }

  /// Back to the normal interval once the session is up: the pump shares its
  /// one radio between Bluetooth and Wi-Fi.
  void _relaxBleConnection() {
    final device = _device;
    if (!Platform.isAndroid || device == null || link != LinkKind.bluetooth) {
      return;
    }
    unawaited(
      device
          .requestConnectionPriority(
            connectionPriorityRequest: ConnectionPriority.balanced,
          )
          .catchError((Object e) {
            AppLog.w('ble', 'Connection priority not set: $e');
          }),
    );
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

  /// A characteristic over whichever link is open.
  PumpChr _chr(Guid uuid) {
    final wifi = _wifi;
    if (wifi != null) return wifi.chr(uuid);
    return BleChr(
      _service!.characteristics.firstWhere(
        (c) => c.uuid == uuid,
        orElse: () => throw StateError('Pump is missing a characteristic'),
      ),
    );
  }

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
    _applyTankStatus(TankStatus.parse(await _tank!.read()));
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
    _applySchedule(ScheduleState.parse(await chr.read()));
    notifyListeners();
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
        unawaited(
          syncPumpClock().catchError((Object e) {
            AppLog.w('pump', 'Clock sync failed: $e'); // tried again in 15 min
          }),
        );
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
    _applyTanks(TankList.parse(await chr.read()));
    final sensorsChr = _sensorsChr!;
    await _sensorsNotifySub?.cancel();
    await sensorsChr.setNotifyValue(true);
    _sensorsNotifySub = sensorsChr.onValueReceived.listen((value) {
      _applySensors(TankSensor.parseList(value));
      notifyListeners();
    });
    _applySensors(TankSensor.parseList(await sensorsChr.read()));
    // Reads and notifies give the newest page; the rest is read page by page.
    _historyNotifySub = await _follow(_historyChr!, _historyNotifySub, (v) {
      final page = HistoryPage.parse(v);
      if (page == null || page.start != 0) return;
      if (page.total <= page.fills.length) {
        fills = page.fills;
      } else {
        unawaited(_readAllHistory());
      }
    });
    _batteryNotifySub = await _follow(_batteryChr!, _batteryNotifySub, (v) {
      final logs = parseBatteryLog(v);
      if (logs != null) batteryLogs = logs;
      _applySimulatedErrors();
    });
  }

  Future<void>? _historyRead;

  /// All of the pump's fills, [TankLinkUuids.historyPage] at a time: write
  /// the start, then read. One read at a time.
  Future<void> _readAllHistory() => _historyRead ??= () async {
    try {
      final chr = _historyChr;
      if (chr == null) return;
      final all = <FillRecord>[];
      var total = 1;
      while (all.length < total) {
        await chr.write([all.length], withoutResponse: false);
        final page = HistoryPage.parse(await chr.read());
        if (page == null || page.fills.isEmpty) break;
        total = page.total;
        all.addAll(page.fills);
      }
      fills = all;
      notifyListeners();
    } catch (e) {
      AppLog.w('pump', 'History read failed: $e');
    } finally {
      _historyRead = null;
    }
  }();

  /// Subscribe to [chr], apply each value with [apply], and read it once. A
  /// failed read fails the session (and the connect is tried again) rather
  /// than leaving a screen on stale or empty data.
  Future<StreamSubscription<List<int>>> _follow(
    PumpChr chr,
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
    } catch (_) {
      await sub.cancel();
      rethrow;
    }
    return sub;
  }

  void _applyTanks(TankList? list) {
    if (list == null) {
      AppLog.w('pump', 'Tank list did not parse');
      return;
    }
    activeSlot = list.activeSlot;
    tanks = list.slots;
    unawaited(syncAlertBridge()); // tank names are in the notification text
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

/// Sign in on a pump's or tank's Auth characteristic: read its nonce, write
/// the answer. The token itself is never sent.
Future<List<int>> signInWith(PumpChr auth, List<int> token) async {
  final nonce = await auth.read();
  await auth.write(authResponse(token, nonce), withoutResponse: false);
  return nonce;
}

const _secure = FlutterSecureStorage();
const _savedPumpsKey = 'saved_pumps';

/// Whether any pump is saved on this phone (for the first-run screen).
Future<bool> hasSavedPumps() async {
  final raw = await _secure.read(key: _savedPumpsKey);
  return raw != null && raw != '[]';
}

/// The pump refused this phone's key over Wi-Fi: it was signed out.
class _SignedOut implements Exception {
  const _SignedOut();
}

/// The Bluetooth scan was stopped because Wi-Fi answered first.
class _ScanCancelled implements Exception {
  const _ScanCancelled();
}
