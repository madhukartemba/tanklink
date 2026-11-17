import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/tanklink_uuids.dart';
import 'github_release_util.dart';
import 'semver.dart';

enum FwUpdatePhase {
  idle,
  checking,
  download,
  preparing,
  transfer,
  verifying,
  rebooting,
  done,
  error,
}

/// One firmware family on GitHub Releases (pump or tank).
class FirmwareChannel {
  const FirmwareChannel({
    required this.tagPrefix,
    required this.binAsset,
    required this.prefsPrefix,
    required this.label,
  });

  /// Release tags look like `<tagPrefix>X.Y.Z`.
  final String tagPrefix;
  final String binAsset;

  /// Prefix for the shared_preferences keys this channel caches under.
  final String prefsPrefix;

  /// Used in error messages: "the pump update".
  final String label;
}

/// A release that passed the manifest checks.
class FirmwareRelease {
  FirmwareRelease({
    required this.version,
    required this.tag,
    required this.binUrl,
    required this.sha256,
    required this.sizeBytes,
    required this.hwRevs,
  });

  final String version;
  final String tag;
  final String binUrl;
  final String sha256;
  final int sizeBytes;

  /// Board revisions this binary is built for.
  final List<int> hwRevs;
}

/// Finds the newest firmware for one board, downloads and verifies it, and
/// tracks progress while the flow sends it over BLE.
///
/// A release is only considered when its `firmware-manifest.json` has a
/// valid sha256, `proto_major` equal to [TankLinkUuids.protoMajor] (so the
/// app can still talk to the board afterwards), and lists the board's
/// revision in `hw_revs`.
class FirmwareUpdate extends ChangeNotifier {
  FirmwareUpdate(this.channel);

  static const repoOwner = 'madhukartemba';
  static const repoName = 'tanklink';
  static const manifestAsset = 'firmware-manifest.json';
  static const _recheckAfter = Duration(hours: 20);

  final FirmwareChannel channel;

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
  String? latestTag;
  List<int> latestHwRevs = const [];

  /// Revision of the connected board, 0 while unknown.
  int _boardRev = 0;
  DateTime? _checkedAt;
  double _emaBps = 0;
  DateTime? _transferStarted;

  String _key(String name) => '${channel.prefsPrefix}$name';

  /// Called whenever the connected board changes. A cached release made for
  /// another revision is dropped so the next check looks again.
  void setBoardRev(int rev) {
    if (rev == _boardRev) return;
    _boardRev = rev;
    if (rev != 0 && !latestHwRevs.contains(rev)) {
      _checkedAt = null;
    }
  }

  bool updateAvailableFor(String deviceFw) {
    final latest = SemVer.tryParse(latestVersion);
    final device = SemVer.tryParse(deviceFw);
    if (latest == null || device == null) return false;
    // 0.0.0 means the board has not reported a version yet.
    if (device.major == 0 && device.minor == 0 && device.patch == 0) {
      return false;
    }
    if (_boardRev == 0 || !latestHwRevs.contains(_boardRev)) return false;
    if (!(latest > device)) return false;
    final snoozed = SemVer.tryParse(snoozedVersion);
    if (snoozed != null && snoozed.compareTo(latest) >= 0) return false;
    return true;
  }

  bool showHomeBanner(String deviceFw) => updateAvailableFor(deviceFw);

  Future<File> _binFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'firmware', channel.binAsset));
  }

  Future<void> loadCache() async {
    final prefs = await SharedPreferences.getInstance();
    latestVersion = prefs.getString(_key('latest_version'));
    snoozedVersion = prefs.getString(_key('snoozed_version'));
    latestSha256 = prefs.getString(_key('latest_sha256'));
    latestBinUrl = prefs.getString(_key('latest_bin_url'));
    latestTag = prefs.getString(_key('latest_tag'));
    latestHwRevs = (prefs.getStringList(_key('latest_hw_revs')) ?? const [])
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    bytesTotal = prefs.getInt(_key('latest_size')) ?? 0;
    final ms = prefs.getInt(_key('checked_at_ms'));
    if (ms != null) {
      _checkedAt = DateTime.fromMillisecondsSinceEpoch(ms);
    }
    final bin = await _binFile();
    if (await bin.exists()) {
      cachedBinPath = bin.path;
    }
    notifyListeners();
  }

  Future<void> snoozeLatest() async {
    if (latestVersion == null) return;
    snoozedVersion = latestVersion;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key('snoozed_version'), latestVersion!);
    notifyListeners();
  }

  Future<void> clearSnooze() async {
    snoozedVersion = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key('snoozed_version'));
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
        DateTime.now().difference(_checkedAt!) < _recheckAfter &&
        latestVersion != null) {
      return;
    }

    phase = FwUpdatePhase.checking;
    errorMessage = null;
    notifyListeners();

    try {
      final release = await _fetchLatestRelease();
      _checkedAt = DateTime.now();
      if (release != null) {
        await _remember(release);
      }
      phase = FwUpdatePhase.idle;
      notifyListeners();
    } catch (e) {
      debugPrint('${channel.label} update check failed: $e');
      errorMessage = 'Couldn’t check for ${channel.label} updates';
      phase = FwUpdatePhase.idle;
      notifyListeners();
    }
  }

  Future<void> _remember(FirmwareRelease release) async {
    latestVersion = release.version;
    latestSha256 = release.sha256;
    latestBinUrl = release.binUrl;
    latestTag = release.tag;
    latestHwRevs = release.hwRevs;
    bytesTotal = release.sizeBytes;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key('latest_version'), release.version);
    await prefs.setString(_key('latest_sha256'), release.sha256);
    await prefs.setString(_key('latest_bin_url'), release.binUrl);
    await prefs.setString(_key('latest_tag'), release.tag);
    await prefs.setStringList(_key('latest_hw_revs'), [
      for (final r in release.hwRevs) '$r',
    ]);
    await prefs.setInt(_key('latest_size'), release.sizeBytes);
    await prefs.setInt(
      _key('checked_at_ms'),
      _checkedAt!.millisecondsSinceEpoch,
    );

    // Drop a cached binary from an older release.
    if (cachedBinPath != null) {
      final f = File(cachedBinPath!);
      if (await f.exists() &&
          sha256.convert(await f.readAsBytes()).toString() != release.sha256) {
        await f.delete();
        cachedBinPath = null;
      }
    }
  }

  Future<Uint8List> ensureBinaryDownloaded() async {
    if (latestSha256 == null || latestBinUrl == null) {
      throw StateError(
        'No ${channel.label} release found. Check for updates first.',
      );
    }
    if (cachedBinPath != null) {
      final f = File(cachedBinPath!);
      if (await f.exists()) {
        final bytes = await f.readAsBytes();
        if (sha256.convert(bytes).toString() == latestSha256) {
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
      final res = await client.send(
        http.Request('GET', Uri.parse(latestBinUrl!)),
      );
      if (res.statusCode != 200) {
        throw StateError('Download failed (${res.statusCode})');
      }
      final total = res.contentLength ?? bytesTotal;
      bytesTotal = total > 0 ? total : bytesTotal;
      final chunks = BytesBuilder(copy: false);
      final started = DateTime.now();
      await for (final chunk in res.stream) {
        chunks.add(chunk);
        bytesDone = chunks.length;
        final elapsed = DateTime.now().difference(started).inMilliseconds;
        if (elapsed > 400 && bytesDone > 0 && bytesTotal > 0) {
          final bps = bytesDone / (elapsed / 1000.0);
          final left = (bytesTotal - bytesDone) / bps;
          eta = Duration(seconds: left.clamp(1, 600).round());
        }
        notifyListeners();
      }
      final bytes = chunks.takeBytes();
      if (sha256.convert(bytes).toString() != latestSha256) {
        throw StateError(
          'The ${channel.label} update download was damaged. Try again.',
        );
      }
      final out = await _binFile();
      await out.parent.create(recursive: true);
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

  /// Waiting for the board to show up (tank: after its button press).
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

  Future<FirmwareRelease?> _fetchLatestRelease() async {
    final list = await fetchGitHubReleases(owner: repoOwner, repo: repoName);
    final candidates = listTaggedReleasesBySemver(
      releases: list,
      tagPrefix: channel.tagPrefix,
      binAssetName: channel.binAsset,
      manifestAssetName: manifestAsset,
    );
    for (final c in candidates) {
      final man = await fetchReleaseManifest(c.manifestUrl);
      if (man == null) continue;
      final sha = (man['sha256'] as String?)?.toLowerCase();
      final version = man['version'] as String? ?? c.tagVersion;
      final proto = man['proto_major'];
      final hwRevs = (man['hw_revs'] as List<dynamic>? ?? const [])
          .whereType<int>()
          .toList();
      if (sha == null || sha.length != 64) continue;
      if (SemVer.tryParse(version) == null) continue;
      if (proto != TankLinkUuids.protoMajor) continue;
      if (_boardRev != 0 && !hwRevs.contains(_boardRev)) continue;
      return FirmwareRelease(
        version: version,
        tag: c.tag,
        binUrl: c.binUrl,
        sha256: sha,
        sizeBytes: c.sizeBytes,
        hwRevs: hwRevs,
      );
    }
    return null;
  }
}

/// Pump firmware: `pump-vX.Y.Z` releases with `pump_node.bin`.
class PumpFirmwareUpdate extends FirmwareUpdate {
  PumpFirmwareUpdate()
    : super(
        const FirmwareChannel(
          tagPrefix: 'pump-v',
          binAsset: 'pump_node.bin',
          prefsPrefix: 'fw_',
          label: 'pump',
        ),
      );
}

/// Tank firmware: `tank-vX.Y.Z` releases with `tank_node.bin`.
class TankFirmwareUpdate extends FirmwareUpdate {
  TankFirmwareUpdate()
    : super(
        const FirmwareChannel(
          tagPrefix: 'tank-v',
          binAsset: 'tank_node.bin',
          prefsPrefix: 'tank_fw_',
          label: 'tank',
        ),
      );
}
