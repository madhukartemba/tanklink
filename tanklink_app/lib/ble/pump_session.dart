import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tanklink_uuids.dart';

String serialFromDeviceId(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  if (clean.length >= 4) {
    return clean.substring(clean.length - 4);
  }
  if (clean.isEmpty) return '----';
  return clean.padLeft(4, '0');
}

class SavedPump {
  SavedPump({
    required this.remoteId,
    required this.deviceIdHex,
    required this.token,
    String? name,
    String? serial,
  })  : serial = (serial != null && serial.isNotEmpty)
            ? serial.toUpperCase()
            : serialFromDeviceId(deviceIdHex),
        name = _resolveName(name, serial ?? serialFromDeviceId(deviceIdHex));

  final String remoteId;
  final String deviceIdHex;
  final Uint8List token;
  final String name;
  final String serial;

  static String _resolveName(String? name, String serial) {
    if (name == null || name.trim().isEmpty) {
      return 'Pump $serial';
    }
    return name.trim();
  }

  /// "Kitchen · #A1B2"
  String get displayTitle => '$name · #$serial';

  SavedPump copyWith({
    String? remoteId,
    String? name,
    String? deviceIdHex,
    String? serial,
    Uint8List? token,
  }) {
    final id = deviceIdHex ?? this.deviceIdHex;
    return SavedPump(
      remoteId: remoteId ?? this.remoteId,
      deviceIdHex: id,
      token: token ?? this.token,
      name: name ?? this.name,
      serial: serial ?? this.serial,
    );
  }

  Map<String, dynamic> toJson() => {
        'remoteId': remoteId,
        'deviceIdHex': deviceIdHex,
        'token': base64Encode(token),
        'name': name,
        'serial': serial,
      };

  static SavedPump? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final tokenB64 = json['token'] as String?;
    final remoteId = json['remoteId'] as String?;
    final deviceIdHex = json['deviceIdHex'] as String?;
    if (tokenB64 == null || remoteId == null || deviceIdHex == null) {
      return null;
    }
    return SavedPump(
      remoteId: remoteId,
      deviceIdHex: deviceIdHex,
      token: Uint8List.fromList(base64Decode(tokenB64)),
      name: json['name'] as String?,
      serial: json['serial'] as String?,
    );
  }
}

class PumpSession extends ChangeNotifier {
  final List<SavedPump> pumps = [];
  String? selectedRemoteId;

  String status = 'Starting…';
  String firmware = '';
  int autoOffMin = 30;
  int runSeconds = 0;
  int buzzerFlags = TankLinkUuids.buzzEnabled |
      TankLinkUuids.buzzOnButton |
      TankLinkUuids.buzzOnPump |
      TankLinkUuids.buzzOnAutoOff;
  int buzzerTone = 0; // click / soft / sharp / double
  int ledBrightness = 70; // 1-100
  int starterType = TankLinkUuids.starterNone;
  int relayPulseMs = TankLinkUuids.relayPulseMsDefault;
  /// Pump NVS: empty float is wired. The pump applies this; the app only writes it.
  bool emptyFloatConnected = false;
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
  /// Last LoRa packet SNR (dB); null if unknown.
  int? tankSnrDb;
  /// Last pump NeoPixel / start-deny error (0 = none).
  int pumpLastError = 0;
  final List<ScanResult> scanResults = [];

  BluetoothDevice? _device;
  BluetoothCharacteristic? _pair;
  BluetoothCharacteristic? _auth;
  BluetoothCharacteristic? _state;
  BluetoothCharacteristic? _cmd;
  BluetoothCharacteristic? _settings;
  BluetoothCharacteristic? _otaCtrl;
  BluetoothCharacteristic? _otaData;
  BluetoothCharacteristic? _otaStatus;
  BluetoothCharacteristic? _tank;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _pairNotifySub;
  StreamSubscription<List<int>>? _stateNotifySub;
  StreamSubscription<List<int>>? _otaStatusSub;
  StreamSubscription<List<int>>? _tankNotifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _runTicker;
  Timer? _ageTicker;

  bool get tankOtaReady =>
      tankBound &&
      tankBleToken != null &&
      tankBleToken!.length == TankLinkUuids.tokenLen &&
      tankBleToken!.any((b) => b != 0);

  bool get tankFull => (tankFlags & TankLinkUuids.tankFlagFull) != 0;
  bool get tankEmpty => (tankFlags & TankLinkUuids.tankFlagEmpty) != 0;
  bool get tankBatteryLow =>
      tankBound &&
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

  /// Live seconds since last tank LoRa packet (ticks with UI timer).
  int? get tankAgeSec {
    final at = _tankLastHeardAt;
    if (at == null) return null;
    final s = DateTime.now().difference(at).inSeconds;
    if (s < 0) return 0;
    if (s > 0xFFFE) return 0xFFFE;
    return s;
  }

  String get tankAgeLabel {
    final age = tankAgeSec;
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
    if (!tankOnline || tankRssiDbm == null) return 'No signal';
    final q = tankSignalQuality;
    if (q >= 0.75) return 'Strong';
    if (q >= 0.45) return 'Good';
    if (q >= 0.25) return 'Fair';
    return 'Weak';
  }

  String? get pumpErrorTitle {
    switch (pumpLastError) {
      case TankLinkUuids.pumpErrTankFull:
        return 'Tank is full';
      case TankLinkUuids.pumpErrLoraMissing:
        return 'LoRa radio missing';
      case TankLinkUuids.pumpErrTankOffline:
        return 'Tank out of range';
      case TankLinkUuids.pumpErrBlocked:
        return 'Pump start blocked';
      case TankLinkUuids.pumpErrNotPaired:
        return 'Pump not paired';
      default:
        return null;
    }
  }

  String? get pumpErrorDetail {
    switch (pumpLastError) {
      case TankLinkUuids.pumpErrTankFull:
        return 'Cannot start while the tank reports full (pump code 1).';
      case TankLinkUuids.pumpErrLoraMissing:
        return 'RA-02 did not start — check wiring (pump code 2).';
      case TankLinkUuids.pumpErrTankOffline:
        return 'No recent heartbeat from the tank sensor (pump code 3).';
      case TankLinkUuids.pumpErrBlocked:
        return 'OTA or pairing lockout is active (pump code 4).';
      case TankLinkUuids.pumpErrNotPaired:
        return 'Claim this pump from the app first (pump code 5).';
      default:
        return null;
    }
  }

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

    final legacy = prefs.getString('saved_pump');
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
    } else if (legacy != null) {
      final one = SavedPump.fromJson(jsonDecode(legacy) as Map<String, dynamic>);
      if (one != null) {
        pumps.add(one);
        await prefs.setString('saved_pumps', jsonEncode([one.toJson()]));
        await prefs.remove('saved_pump');
      }
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
        debugPrint('auth write failed: $e');
        await disconnect();
        connecting = false;
        connectFailed = true;
        status = 'Auth failed — hold pump 5s, then Add pump again';
        notifyListeners();
        return;
      }
      authed = true;
      await _state!.setNotifyValue(true);
      final stateVal = await _state!.read();
      if (stateVal.isNotEmpty) {
        _applyPumpOn(stateVal[0] != 0);
      }
      await _refreshInfoAndSettings();
      connecting = false;
      connectFailed = false;
      status = 'Connected';
      notifyListeners();
      // Soft trigger for firmware check (listener may also call this).
    } catch (e) {
      debugPrint('connectSelected failed: $e');
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
    final hasSvc = r.advertisementData.serviceUuids
        .any((u) => u == TankLinkUuids.service);
    final looksLikeUs = name.startsWith(TankLinkUuids.deviceNamePrefix) ||
        name.contains('TankLink') ||
        hasSvc;
    if (!looksLikeUs) {
      return false;
    }
    final upper = name.toUpperCase();
    return upper.endsWith(serial) ||
        upper.contains('-$serial') ||
        upper.contains('#$serial') ||
        upper.contains(serial);
  }

  Future<void> _refreshInfoAndSettings() async {
    try {
      final infoChr = (await _device!.discoverServices())
          .firstWhere((s) => s.uuid == TankLinkUuids.service)
          .characteristics
          .firstWhere((c) => c.uuid == TankLinkUuids.info);
      final bytes = await infoChr.read();
      final parsed = _parseInfo(bytes);
      firmware = parsed.fw;
      autoOffMin = parsed.autoOffMin;
      if (parsed.runSeconds > 0) {
        runSeconds = parsed.runSeconds;
      }
      final cur = selected;
      if (cur != null &&
          (cur.deviceIdHex != parsed.deviceIdHex ||
              cur.serial != parsed.serial)) {
        await _upsertPump(
          cur.copyWith(
            deviceIdHex: parsed.deviceIdHex,
            serial: parsed.serial,
          ),
        );
      }
    } catch (_) {}

    if (_settings != null) {
      try {
        final bytes = await _settings!.read();
        if (bytes.isNotEmpty) {
          autoOffMin = bytes[0];
        }
        if (bytes.length >= 5) {
          runSeconds = bytes[1] |
              (bytes[2] << 8) |
              (bytes[3] << 16) |
              (bytes[4] << 24);
        }
        // auto(1)+run(4)+serial(5)=10, then flags + tone [+ led bri]
        if (bytes.length >= 12) {
          buzzerFlags = bytes[10];
          buzzerTone = bytes[11].clamp(0, 3);
        }
        if (bytes.length >= 13) {
          ledBrightness = bytes[12].clamp(1, 100);
        }
        if (bytes.length >= 14) {
          starterType = bytes[13];
        }
        if (bytes.length >= 16) {
          final ms = bytes[14] | (bytes[15] << 8);
          relayPulseMs = ms
              .clamp(
                TankLinkUuids.relayPulseMsMin,
                TankLinkUuids.relayPulseMsMax,
              )
              .toInt();
        }
        if (bytes.length >= 17) {
          emptyFloatConnected = bytes[16] != 0;
        }
      } catch (_) {}
    }
  }

  bool get buzzerEnabled => (buzzerFlags & TankLinkUuids.buzzEnabled) != 0;
  bool get buzzOnButton => (buzzerFlags & TankLinkUuids.buzzOnButton) != 0;
  bool get buzzOnPump => (buzzerFlags & TankLinkUuids.buzzOnPump) != 0;
  bool get buzzOnAutoOff => (buzzerFlags & TankLinkUuids.buzzOnAutoOff) != 0;

  ({
    bool paired,
    String deviceIdHex,
    String serial,
    String fw,
    int autoOffMin,
    int runSeconds,
  }) _parseInfo(List<int> bytes) {
    if (bytes.length < 7) {
      throw StateError('Info too short');
    }
    final paired = bytes[0] != 0;
    final id = bytes.sublist(1, 7);
    final hex = id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final serial = serialFromDeviceId(hex);
    var i = 7;
    final fwChars = <int>[];
    while (i < bytes.length && bytes[i] != 0) {
      fwChars.add(bytes[i]);
      i++;
    }
    if (i < bytes.length && bytes[i] == 0) i++;
    final fw = utf8.decode(fwChars);
    var autoOff = 30;
    var run = 0;
    if (i < bytes.length) {
      autoOff = bytes[i];
      i++;
    }
    if (i < bytes.length) {
      i++; // flags
    }
    if (i + 3 < bytes.length) {
      run = bytes[i] |
          (bytes[i + 1] << 8) |
          (bytes[i + 2] << 16) |
          (bytes[i + 3] << 24);
    }
    return (
      paired: paired,
      deviceIdHex: hex,
      serial: serial,
      fw: fw,
      autoOffMin: autoOff,
      runSeconds: run,
    );
  }

  Future<void> _writeSettings({
    int? minutes,
    int? flags,
    int? tone,
    int? brightness,
    int? starter,
    int? pulseMs,
    bool? emptyFloat,
  }) async {
    if (_settings == null || !authed) {
      status = 'Not connected';
      notifyListeners();
      return;
    }
    final m = (minutes ?? autoOffMin).clamp(0, 240);
    final f = flags ?? buzzerFlags;
    final t = (tone ?? buzzerTone).clamp(0, 3);
    final b = (brightness ?? ledBrightness).clamp(1, 100);
    final s = (starter ?? starterType).clamp(0, 1);
    final p = (pulseMs ?? relayPulseMs).clamp(
      TankLinkUuids.relayPulseMsMin,
      TankLinkUuids.relayPulseMsMax,
    );
    final empty = emptyFloat ?? emptyFloatConnected;
    await _settings!.write(
      [m, f, t, b, s, p & 0xff, (p >> 8) & 0xff, empty ? 1 : 0],
      withoutResponse: false,
    );
    autoOffMin = m;
    buzzerFlags = f;
    buzzerTone = t;
    ledBrightness = b;
    starterType = s;
    relayPulseMs = p;
    emptyFloatConnected = empty;
    notifyListeners();
  }

  Future<void> setAutoOffMinutes(int minutes) async {
    await _writeSettings(minutes: minutes);
    // Keep status quiet — avoids UI churn while dragging the slider.
  }

  Future<void> setLedBrightness(int percent) async {
    await _writeSettings(brightness: percent.clamp(1, 100));
  }

  Future<void> setEmptyFloatConnected(bool connected) async {
    await _writeSettings(emptyFloat: connected);
    status = connected ? 'Empty float connected' : 'Empty float ignored';
    notifyListeners();
  }

  Future<void> setStarterType(int type) async {
    await _writeSettings(starter: type.clamp(0, 1));
    status = type == TankLinkUuids.starterTwoButton
        ? 'Two-button starter'
        : 'Starter: none';
    notifyListeners();
  }

  Future<void> setStarterConfig({required int type, required int pulseMs}) async {
    await _writeSettings(
      starter: type.clamp(0, 1),
      pulseMs: pulseMs.clamp(
        TankLinkUuids.relayPulseMsMin,
        TankLinkUuids.relayPulseMsMax,
      ),
    );
    status = type == TankLinkUuids.starterTwoButton
        ? 'Two-button · ${relayPulseMs} ms'
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

  void _applyTankStatus(List<int> bytes) {
    if (bytes.length < 13) return;
    tankBound = bytes[0] != 0;
    tankPairing = bytes[1] != 0;
    tankIdHex = bytes
        .sublist(2, 8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final maj = bytes[8];
    final min = bytes[9];
    final pat = bytes[10];
    // 0.0.0 means "never heard / unknown" — don't treat as a real FW version.
    tankFw = (maj == 0 && min == 0 && pat == 0) ? '' : '$maj.$min.$pat';
    tankFlags = bytes[11];
    tankBatteryPct = bytes[12].clamp(0, 100);
    if (bytes.length >= 16) {
      tankOnline = bytes[13] != 0;
      final age = bytes[14] | (bytes[15] << 8);
      if (age == 0xFFFF) {
        _tankLastHeardAt = null;
      } else {
        _tankLastHeardAt =
            DateTime.now().subtract(Duration(seconds: age.clamp(0, 0xFFFE)));
      }
    } else {
      tankOnline = tankBound;
      _tankLastHeardAt = null;
    }
    if (bytes.length >= 18) {
      tankRssiDbm = bytes[16] > 127 ? bytes[16] - 256 : bytes[16];
      tankSnrDb = bytes[17] > 127 ? bytes[17] - 256 : bytes[17];
    } else {
      tankRssiDbm = null;
      tankSnrDb = null;
    }
    pumpLastError = bytes.length >= 19 ? bytes[18] : 0;
    if (bytes.length >= TankLinkUuids.tankStatusWithTokenLen) {
      final tok = Uint8List.fromList(
        bytes.sublist(19, 19 + TankLinkUuids.tokenLen),
      );
      tankBleToken = tok.any((b) => b != 0) ? tok : null;
    } else {
      tankBleToken = null;
    }
    if (!tankBound) {
      tankOnline = false;
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
    _ensureAgeTicker();
  }

  void _ensureAgeTicker() {
    if (!authed || !connected || !tankBound || _tankLastHeardAt == null) {
      _ageTicker?.cancel();
      _ageTicker = null;
      return;
    }
    _ageTicker ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (!authed || !connected || _tankLastHeardAt == null) {
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

  Future<void> unpairTank() async {
    if (_cmd == null || !authed) {
      throw StateError('Not connected');
    }
    await _cmd!.write([TankLinkUuids.cmdTankUnpair], withoutResponse: false);
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
    pumpLastError = TankLinkUuids.pumpErrNone;
    notifyListeners();
    if (_cmd == null || !authed) return;
    try {
      await _cmd!.write([TankLinkUuids.cmdClearError], withoutResponse: false);
    } catch (_) {
      /* Local clear already applied. */
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
        final hasSvc = r.advertisementData.serviceUuids
            .any((u) => u == TankLinkUuids.service);
        final match = name == TankLinkUuids.deviceName ||
            name.startsWith(TankLinkUuids.deviceNamePrefix) ||
            name.contains('TankLink') ||
            hasSvc;
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
    final info = _parseInfo(await _readInfoBytes());
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
    firmware = info.fw;
    autoOffMin = info.autoOffMin;
    await _state!.setNotifyValue(true);
    // Refresh tank bind status after claim (char may already be subscribed).
    try {
      if (_tank != null) {
        _applyTankStatus(await _tank!.read());
      }
    } catch (_) {}
    status = 'Connected';
    notifyListeners();
  }

  Future<List<int>> _readInfoBytes() async {
    final infoChr = (await _device!.discoverServices())
        .firstWhere((s) => s.uuid == TankLinkUuids.service)
        .characteristics
        .firstWhere((c) => c.uuid == TankLinkUuids.info);
    return infoChr.read();
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

  /// Scan for the bound tank advertising after a button press, then BLE OTA.
  Future<void> otaUpdateTank(
    Uint8List image, {
    void Function()? onScanning,
    void Function(int done, int total)? onProgress,
    void Function()? onVerifying,
    void Function()? onRebooting,
  }) async {
    if (!tankOtaReady || tankIdHex.isEmpty) {
      throw StateError('Re-pair the tank sensor to enable updates');
    }
    final wantId = tankIdHex.toLowerCase().replaceAll(':', '');
    final token = Uint8List.fromList(tankBleToken!);

    onScanning?.call();
    await FlutterBluePlus.stopScan();
    BluetoothDevice? tankDevice;
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName;
        if (!name.startsWith(TankLinkUuids.tankAdvNamePrefix) &&
            !name.startsWith('TL-Tank')) {
          // Still allow mfg-data match without name.
        }
        final mfg = r.advertisementData.manufacturerData;
        for (final entry in mfg.entries) {
          final data = entry.value;
          // FBP: key = company ID, value = payload after company bytes.
          if (data.length < 6) continue;
          final idBytes = data.length >= 8
              ? data.sublist(data.length - 6)
              : data.sublist(0, 6);
          final hex = idBytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          if (hex == wantId) {
            tankDevice = r.device;
            return;
          }
        }
        // Fallback: serial suffix in name TL-Tank-XXXX
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
      final services = await device.discoverServices();
      BluetoothCharacteristic? authChr;
      BluetoothCharacteristic? otaCtrlChr;
      BluetoothCharacteristic? otaDataChr;
      BluetoothCharacteristic? otaStatusChr;
      for (final s in services) {
        if (s.uuid != TankLinkUuids.service) continue;
        for (final c in s.characteristics) {
          if (c.uuid == TankLinkUuids.auth) authChr = c;
          if (c.uuid == TankLinkUuids.otaCtrl) otaCtrlChr = c;
          if (c.uuid == TankLinkUuids.otaData) otaDataChr = c;
          if (c.uuid == TankLinkUuids.otaStatus) otaStatusChr = c;
        }
      }
      if (authChr == null ||
          otaCtrlChr == null ||
          otaDataChr == null ||
          otaStatusChr == null) {
        throw StateError('Tank firmware does not support BLE OTA yet');
      }
      final auth = authChr;
      final otaCtrl = otaCtrlChr;
      final otaData = otaDataChr;
      final otaStatus = otaStatusChr;
      await auth.write(token, withoutResponse: false);

      final digest = sha256.convert(image);
      final shaBytes = Uint8List.fromList(digest.bytes);
      final size = image.length;

      await otaStatus.setNotifyValue(true);
      final statusCtrl = StreamController<List<int>>.broadcast();
      final statusSub = otaStatus.onValueReceived.listen(statusCtrl.add);

      Future<List<int>> waitStatus({
        required bool Function(int state, int err) match,
        Duration timeout = const Duration(seconds: 20),
      }) async {
        final existing = await otaStatus.read();
        if (existing.length >= 2 && match(existing[0], existing[1])) {
          return existing;
        }
        return statusCtrl.stream
            .where((v) => v.length >= 2 && match(v[0], v[1]))
            .first
            .timeout(timeout);
      }

      try {
        final start = BytesBuilder();
        start.addByte(TankLinkUuids.otaOpStart);
        start.addByte(size & 0xff);
        start.addByte((size >> 8) & 0xff);
        start.addByte((size >> 16) & 0xff);
        start.addByte((size >> 24) & 0xff);
        start.add(shaBytes);
        await otaCtrl.write(start.toBytes(), withoutResponse: false);
        await waitStatus(
          match: (st, err) =>
              (st == TankLinkUuids.otaStReady ||
                  st == TankLinkUuids.otaStWriting) &&
              err == 0,
        );

        final mtu = device.mtuNow;
        final maxChunk = (mtu - 3 - 4).clamp(20, 480);
        var offset = 0;
        while (offset < size) {
          final end = (offset + maxChunk).clamp(0, size);
          final chunk = image.sublist(offset, end);
          final packet = BytesBuilder();
          packet.addByte(offset & 0xff);
          packet.addByte((offset >> 8) & 0xff);
          packet.addByte((offset >> 16) & 0xff);
          packet.addByte((offset >> 24) & 0xff);
          packet.add(chunk);
          await otaData.write(packet.toBytes(), withoutResponse: false);
          offset = end;
          onProgress?.call(offset, size);
        }

        onVerifying?.call();
        await otaCtrl.write([TankLinkUuids.otaOpFinish], withoutResponse: false);
        await waitStatus(
          match: (st, err) =>
              (st == TankLinkUuids.otaStVerifyOk ||
                  st == TankLinkUuids.otaStRebooting) &&
              err == 0,
          timeout: const Duration(seconds: 30),
        );
        onRebooting?.call();
        await Future<void>.delayed(const Duration(seconds: 2));
      } catch (e) {
        try {
          await otaCtrl.write([TankLinkUuids.otaOpAbort], withoutResponse: false);
        } catch (_) {}
        rethrow;
      } finally {
        await statusSub.cancel();
        await statusCtrl.close();
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
    if (_otaCtrl == null || _otaData == null || _otaStatus == null) {
      throw StateError('This pump firmware does not support BLE OTA yet');
    }

    final digest = sha256.convert(image);
    final shaBytes = Uint8List.fromList(digest.bytes);
    final size = image.length;

    await _otaStatus!.setNotifyValue(true);
    await _otaStatusSub?.cancel();
    final statusCtrl = StreamController<List<int>>.broadcast();
    _otaStatusSub = _otaStatus!.onValueReceived.listen(statusCtrl.add);

    Future<List<int>> waitStatus({
      required bool Function(int state, int err) match,
      Duration timeout = const Duration(seconds: 20),
    }) async {
      final existing = await _otaStatus!.read();
      if (existing.length >= 2 && match(existing[0], existing[1])) {
        return existing;
      }
      return statusCtrl.stream
          .where((v) => v.length >= 2 && match(v[0], v[1]))
          .first
          .timeout(timeout);
    }

    try {
      final start = BytesBuilder();
      start.addByte(TankLinkUuids.otaOpStart);
      start.addByte(size & 0xff);
      start.addByte((size >> 8) & 0xff);
      start.addByte((size >> 16) & 0xff);
      start.addByte((size >> 24) & 0xff);
      start.add(shaBytes);
      await _otaCtrl!.write(start.toBytes(), withoutResponse: false);
      await waitStatus(
        match: (st, err) =>
            (st == TankLinkUuids.otaStReady || st == TankLinkUuids.otaStWriting) &&
            err == 0,
      );

      // ATT payload ≈ MTU - 3; leave room for 4-byte offset header.
      final mtu = _device?.mtuNow ?? 23;
      final maxChunk = (mtu - 3 - 4).clamp(20, 480);

      var offset = 0;
      while (offset < size) {
        final end = (offset + maxChunk).clamp(0, size);
        final chunk = image.sublist(offset, end);
        final packet = BytesBuilder();
        packet.addByte(offset & 0xff);
        packet.addByte((offset >> 8) & 0xff);
        packet.addByte((offset >> 16) & 0xff);
        packet.addByte((offset >> 24) & 0xff);
        packet.add(chunk);
        // Prefer write-with-response for reliability on OTA data.
        await _otaData!.write(packet.toBytes(), withoutResponse: false);
        offset = end;
        onProgress?.call(offset, size);
      }

      onVerifying?.call();
      await _otaCtrl!
          .write([TankLinkUuids.otaOpFinish], withoutResponse: false);
      await waitStatus(
        match: (st, err) =>
            (st == TankLinkUuids.otaStVerifyOk ||
                st == TankLinkUuids.otaStRebooting) &&
            err == 0,
        timeout: const Duration(seconds: 30),
      );
      onRebooting?.call();

      // Device reboots — wait for disconnect then reconnect.
      await Future<void>.delayed(const Duration(seconds: 2));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        try {
          await connectSelected();
          if (authed && connected) {
            return;
          }
        } catch (_) {}
      }
      throw StateError('Updated, but couldn’t reconnect — try Connect');
    } catch (e) {
      try {
        await _otaCtrl
            ?.write([TankLinkUuids.otaOpAbort], withoutResponse: false);
      } catch (_) {}
      rethrow;
    } finally {
      await _otaStatusSub?.cancel();
      _otaStatusSub = null;
      await statusCtrl.close();
    }
  }

  Future<void> disconnect() async {
    _runTicker?.cancel();
    _runTicker = null;
    _ageTicker?.cancel();
    _ageTicker = null;
    await _pairNotifySub?.cancel();
    await _stateNotifySub?.cancel();
    await _otaStatusSub?.cancel();
    await _tankNotifySub?.cancel();
    await _connSub?.cancel();
    _pairNotifySub = null;
    _stateNotifySub = null;
    _otaStatusSub = null;
    _tankNotifySub = null;
    _connSub = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _pair = _auth = _state = _cmd = _settings = null;
    _otaCtrl = _otaData = _otaStatus = _tank = null;
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
    tankSnrDb = null;
    pumpLastError = 0;
    notifyListeners();
  }

  Future<void> disconnectAndStay() async {
    await disconnect();
    connectFailed = true;
    status = 'Disconnected';
    notifyListeners();
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
      if (!connected) {
        authed = false;
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
    _pair =
        svc.characteristics.firstWhere((c) => c.uuid == TankLinkUuids.pair);
    _auth =
        svc.characteristics.firstWhere((c) => c.uuid == TankLinkUuids.auth);
    _state =
        svc.characteristics.firstWhere((c) => c.uuid == TankLinkUuids.state);
    _cmd = svc.characteristics.firstWhere((c) => c.uuid == TankLinkUuids.cmd);
    try {
      _settings = svc.characteristics
          .firstWhere((c) => c.uuid == TankLinkUuids.settings);
    } catch (_) {
      _settings = null;
    }
    try {
      _otaCtrl = svc.characteristics
          .firstWhere((c) => c.uuid == TankLinkUuids.otaCtrl);
      _otaData = svc.characteristics
          .firstWhere((c) => c.uuid == TankLinkUuids.otaData);
      _otaStatus = svc.characteristics
          .firstWhere((c) => c.uuid == TankLinkUuids.otaStatus);
    } catch (_) {
      _otaCtrl = _otaData = _otaStatus = null;
    }
    try {
      _tank =
          svc.characteristics.firstWhere((c) => c.uuid == TankLinkUuids.tank);
    } catch (_) {
      _tank = null;
    }

    try {
      await device.requestMtu(512);
    } catch (_) {}

    await _stateNotifySub?.cancel();
    _stateNotifySub = _state!.onValueReceived.listen((value) {
      if (value.isNotEmpty) {
        _applyPumpOn(value[0] != 0);
        notifyListeners();
      }
    });

    await _tankNotifySub?.cancel();
    if (_tank != null) {
      await _tank!.setNotifyValue(true);
      _tankNotifySub = _tank!.onValueReceived.listen((value) {
        _applyTankStatus(value);
        notifyListeners();
      });
      try {
        final v = await _tank!.read();
        _applyTankStatus(v);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _runTicker?.cancel();
    _ageTicker?.cancel();
    unawaited(disconnect());
    unawaited(stopScan());
    super.dispose();
  }
}
