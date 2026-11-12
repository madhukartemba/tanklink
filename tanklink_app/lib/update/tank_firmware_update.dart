import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pump_firmware_update.dart' show FwUpdatePhase;
import 'semver.dart';

class TankReleaseInfo {
  TankReleaseInfo({
    required this.version,
    required this.tag,
    required this.binUrl,
    required this.manifestUrl,
    required this.sha256,
    required this.sizeBytes,
  });

  final String version;
  final String tag;
  final String binUrl;
  final String manifestUrl;
  final String sha256;
  final int sizeBytes;
}

/// Checks GitHub Releases for newer tank firmware (`tank-v*`) and caches the .bin.
class TankFirmwareUpdate extends ChangeNotifier {
  static const repoOwner = 'madhukartemba';
  static const repoName = 'tanklink';
  static const _prefsLatest = 'tank_fw_latest_version';
  static const _prefsChecked = 'tank_fw_checked_at_ms';
  static const _prefsSnooze = 'tank_fw_snoozed_version';
  static const _prefsSha = 'tank_fw_latest_sha256';
  static const _prefsSize = 'tank_fw_latest_size';
  static const _prefsBinUrl = 'tank_fw_latest_bin_url';
  static const _prefsManifestUrl = 'tank_fw_latest_manifest_url';
  static const _prefsTag = 'tank_fw_latest_tag';

  FwUpdatePhase phase = FwUpdatePhase.idle;
  String? latestVersion;
  String? snoozedVersion;
  String? errorMessage;
  int bytesDone = 0;
  int bytesTotal = 0;
  Duration? eta;
  String? cachedBinPath;
  String? latestSha256;
  String? latestBinUrl;
  String? latestManifestUrl;
  String? latestTag;

  DateTime? _checkedAt;
  double _emaBps = 0;
  DateTime? _transferStarted;

  bool updateAvailableFor(String deviceFw) {
    final trimmed = deviceFw.trim();
    if (trimmed.isEmpty || trimmed == '0.0.0') return false;
    final latest = SemVer.tryParse(latestVersion);
    final device = SemVer.tryParse(trimmed);
    if (latest == null || device == null) return false;
    if (device.major == 0 && device.minor == 0 && device.patch == 0) {
      return false;
    }
    if (!(latest > device)) return false;
    if (snoozedVersion != null &&
        SemVer.tryParse(snoozedVersion) != null &&
        SemVer.tryParse(snoozedVersion)!.compareTo(latest) >= 0) {
      return false;
    }
    return true;
  }

  bool showHomeBanner(String deviceFw) => updateAvailableFor(deviceFw);

  Future<void> loadCache() async {
    final prefs = await SharedPreferences.getInstance();
    latestVersion = prefs.getString(_prefsLatest);
    snoozedVersion = prefs.getString(_prefsSnooze);
    latestSha256 = prefs.getString(_prefsSha);
    latestBinUrl = prefs.getString(_prefsBinUrl);
    latestManifestUrl = prefs.getString(_prefsManifestUrl);
    latestTag = prefs.getString(_prefsTag);
    bytesTotal = prefs.getInt(_prefsSize) ?? 0;
    final ms = prefs.getInt(_prefsChecked);
    if (ms != null) {
      _checkedAt = DateTime.fromMillisecondsSinceEpoch(ms);
    }
    final dir = await getApplicationSupportDirectory();
    final bin = File(p.join(dir.path, 'firmware', 'tank_node.bin'));
    if (await bin.exists()) {
      cachedBinPath = bin.path;
    }
    notifyListeners();
  }

  Future<void> snoozeLatest() async {
    if (latestVersion == null) return;
    snoozedVersion = latestVersion;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSnooze, latestVersion!);
    notifyListeners();
  }

  Future<void> clearSnooze() async {
    snoozedVersion = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsSnooze);
    notifyListeners();
  }

  Future<void> checkForUpdates({bool force = false}) async {
    if (phase == FwUpdatePhase.checking ||
        phase == FwUpdatePhase.download ||
        phase == FwUpdatePhase.transfer) {
      return;
    }
    if (!force &&
        _checkedAt != null &&
        DateTime.now().difference(_checkedAt!) < const Duration(hours: 20) &&
        latestVersion != null) {
      return;
    }

    phase = FwUpdatePhase.checking;
    errorMessage = null;
    notifyListeners();

    try {
      final release = await _fetchLatestTankRelease();
      if (release == null) {
        phase = FwUpdatePhase.idle;
        notifyListeners();
        return;
      }
      latestVersion = release.version;
      latestSha256 = release.sha256;
      latestBinUrl = release.binUrl;
      latestManifestUrl = release.manifestUrl;
      latestTag = release.tag;
      bytesTotal = release.sizeBytes;
      _checkedAt = DateTime.now();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsLatest, release.version);
      await prefs.setString(_prefsSha, release.sha256);
      await prefs.setString(_prefsBinUrl, release.binUrl);
      await prefs.setString(_prefsManifestUrl, release.manifestUrl);
      await prefs.setString(_prefsTag, release.tag);
      await prefs.setInt(_prefsSize, release.sizeBytes);
      await prefs.setInt(_prefsChecked, _checkedAt!.millisecondsSinceEpoch);

      if (cachedBinPath != null) {
        final f = File(cachedBinPath!);
        if (await f.exists()) {
          final digest = sha256.convert(await f.readAsBytes()).toString();
          if (digest != release.sha256) {
            await f.delete();
            cachedBinPath = null;
          }
        }
      }

      phase = FwUpdatePhase.idle;
      notifyListeners();
    } catch (e) {
      errorMessage = 'Couldn’t check for tank updates';
      phase = FwUpdatePhase.error;
      notifyListeners();
      phase = FwUpdatePhase.idle;
      notifyListeners();
    }
  }

  Future<Uint8List> ensureBinaryDownloaded() async {
    if (latestSha256 == null || latestBinUrl == null) {
      throw StateError('No tank release cached — check for updates first');
    }
    if (cachedBinPath != null) {
      final f = File(cachedBinPath!);
      if (await f.exists()) {
        final bytes = await f.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        if (digest == latestSha256) {
          return Uint8List.fromList(bytes);
        }
      }
    }

    phase = FwUpdatePhase.download;
    bytesDone = 0;
    eta = null;
    errorMessage = null;
    notifyListeners();

    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(latestBinUrl!));
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw StateError('Download failed (${res.statusCode})');
      }
      final total = res.contentLength ?? bytesTotal;
      bytesTotal = total > 0 ? total : bytesTotal;
      final chunks = <int>[];
      final started = DateTime.now();
      await for (final chunk in res.stream) {
        chunks.addAll(chunk);
        bytesDone = chunks.length;
        final elapsed = DateTime.now().difference(started).inMilliseconds;
        if (elapsed > 400 && bytesDone > 0 && bytesTotal > 0) {
          final bps = bytesDone / (elapsed / 1000.0);
          final left = (bytesTotal - bytesDone) / bps;
          eta = Duration(seconds: left.clamp(1, 600).round());
        }
        notifyListeners();
      }
      final bytes = Uint8List.fromList(chunks);
      final digest = sha256.convert(bytes).toString();
      if (digest != latestSha256) {
        throw StateError('Downloaded tank firmware failed integrity check');
      }
      final dir = await getApplicationSupportDirectory();
      final outDir = Directory(p.join(dir.path, 'firmware'));
      await outDir.create(recursive: true);
      final out = File(p.join(outDir.path, 'tank_node.bin'));
      await out.writeAsBytes(bytes, flush: true);
      cachedBinPath = out.path;
      phase = FwUpdatePhase.idle;
      notifyListeners();
      return bytes;
    } catch (e) {
      errorMessage = e.toString();
      phase = FwUpdatePhase.error;
      notifyListeners();
      rethrow;
    } finally {
      client.close();
    }
  }

  void beginTransfer(int total) {
    phase = FwUpdatePhase.preparing;
    bytesDone = 0;
    bytesTotal = total;
    eta = null;
    _emaBps = 0;
    _transferStarted = DateTime.now();
    errorMessage = null;
    notifyListeners();
  }

  void setTransferProgress(int done, int total) {
    phase = FwUpdatePhase.transfer;
    bytesDone = done;
    bytesTotal = total;
    final started = _transferStarted;
    if (started != null && done > total * 0.05) {
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      if (elapsed > 200) {
        final bps = done / (elapsed / 1000.0);
        _emaBps = _emaBps == 0 ? bps : (_emaBps * 0.7 + bps * 0.3);
        if (_emaBps > 1) {
          final left = (total - done) / _emaBps;
          eta = Duration(seconds: left.clamp(1, 900).round());
        }
      }
    }
    notifyListeners();
  }

  void setScanning() {
    phase = FwUpdatePhase.preparing;
    eta = null;
    notifyListeners();
  }

  void setVerifying() {
    phase = FwUpdatePhase.verifying;
    eta = null;
    notifyListeners();
  }

  void setRebooting() {
    phase = FwUpdatePhase.rebooting;
    notifyListeners();
  }

  void setDone() {
    phase = FwUpdatePhase.done;
    notifyListeners();
  }

  void setError(String message) {
    errorMessage = message;
    phase = FwUpdatePhase.error;
    notifyListeners();
  }

  void resetPhase() {
    if (phase == FwUpdatePhase.done || phase == FwUpdatePhase.error) {
      phase = FwUpdatePhase.idle;
      errorMessage = null;
      notifyListeners();
    }
  }

  Future<TankReleaseInfo?> _fetchLatestTankRelease() async {
    final uri = Uri.parse(
      'https://api.github.com/repos/$repoOwner/$repoName/releases?per_page=20',
    );
    final res = await http.get(
      uri,
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'TankLink-App',
      },
    );
    if (res.statusCode != 200) {
      throw StateError('GitHub API ${res.statusCode}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    for (final item in list) {
      final map = item as Map<String, dynamic>;
      if (map['draft'] == true || map['prerelease'] == true) continue;
      final tag = map['tag_name'] as String? ?? '';
      if (!tag.startsWith('tank-v')) continue;
      final version = tag.substring('tank-v'.length);
      if (SemVer.tryParse(version) == null) continue;
      final assets = (map['assets'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      String? binUrl;
      String? manifestUrl;
      int size = 0;
      for (final a in assets) {
        final name = a['name'] as String? ?? '';
        final url = a['browser_download_url'] as String?;
        if (url == null) continue;
        if (name == 'tank_node.bin') {
          binUrl = url;
          size = a['size'] as int? ?? 0;
        } else if (name == 'firmware-manifest.json') {
          manifestUrl = url;
        }
      }
      if (binUrl == null || manifestUrl == null) continue;

      final manRes = await http.get(
        Uri.parse(manifestUrl),
        headers: {'User-Agent': 'TankLink-App'},
      );
      if (manRes.statusCode != 200) continue;
      final man = jsonDecode(manRes.body) as Map<String, dynamic>;
      final sha = (man['sha256'] as String?)?.toLowerCase();
      final manVer = man['version'] as String? ?? version;
      if (sha == null || sha.length != 64) continue;

      return TankReleaseInfo(
        version: manVer,
        tag: tag,
        binUrl: binUrl,
        manifestUrl: manifestUrl,
        sha256: sha,
        sizeBytes: size,
      );
    }
    return null;
  }
}
