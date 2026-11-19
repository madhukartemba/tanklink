import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'github_release_util.dart';
import 'firmware_update.dart' show FwUpdatePhase;
import 'semver.dart';
import '../diag/app_log.dart';

class AppReleaseInfo {
  AppReleaseInfo({
    required this.version,
    required this.tag,
    required this.apkUrl,
    required this.manifestUrl,
    required this.sha256,
    required this.sizeBytes,
  });

  final String version;
  final String tag;
  final String apkUrl;
  final String manifestUrl;
  final String sha256;
  final int sizeBytes;
}

/// GitHub `app-v*` releases → download signed APK (Android sideload).
class AppSelfUpdate extends ChangeNotifier {
  static const repoOwner = 'madhukartemba';
  static const repoName = 'tanklink';
  static const apkAssetName = 'TankLink.apk';

  static const _prefsLatest = 'app_latest_version';
  static const _prefsSnooze = 'app_snoozed_version';
  static const _prefsSha = 'app_latest_sha256';
  static const _prefsApkUrl = 'app_latest_apk_url';
  static const _prefsTag = 'app_latest_tag';
  static const _prefsSize = 'app_latest_size';
  static const _prefsApkPath = 'app_cached_apk_path';
  static const _prefsCheckAt = 'app_last_check_ms';

  FwUpdatePhase phase = FwUpdatePhase.idle;
  String? installedVersion;
  int? installedBuild;
  String? latestVersion;
  String? snoozedVersion;
  String? latestSha256;
  String? latestApkUrl;
  String? latestTag;
  int bytesDone = 0;
  int bytesTotal = 0;
  Duration? eta;
  String? errorMessage;
  String? cachedApkPath;

  bool get enabled => !kIsWeb && Platform.isAndroid;

  bool updateAvailable() {
    if (!enabled) return false;
    final installed = SemVer.tryParse(installedVersion);
    final latest = SemVer.tryParse(latestVersion);
    if (installed == null || latest == null) return false;
    if (!(latest > installed)) return false;
    if (snoozedVersion != null &&
        SemVer.tryParse(snoozedVersion) != null &&
        SemVer.tryParse(snoozedVersion)!.compareTo(latest) >= 0) {
      return false;
    }
    return true;
  }

  Future<void> loadInstalledVersion() async {
    if (!enabled) return;
    final info = await PackageInfo.fromPlatform();
    installedVersion = info.version;
    installedBuild = int.tryParse(info.buildNumber);
    notifyListeners();
  }

  Future<void> loadCache() async {
    if (!enabled) return;
    await loadInstalledVersion();
    final prefs = await SharedPreferences.getInstance();
    latestVersion = prefs.getString(_prefsLatest);
    snoozedVersion = prefs.getString(_prefsSnooze);
    latestSha256 = prefs.getString(_prefsSha);
    latestApkUrl = prefs.getString(_prefsApkUrl);
    latestTag = prefs.getString(_prefsTag);
    bytesTotal = prefs.getInt(_prefsSize) ?? 0;
    cachedApkPath = prefs.getString(_prefsApkPath);
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
    if (!enabled) return;
    if (phase == FwUpdatePhase.checking ||
        phase == FwUpdatePhase.download ||
        phase == FwUpdatePhase.transfer) {
      return;
    }

    if (!force) {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_prefsCheckAt) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - last;
      if (age < const Duration(hours: 6).inMilliseconds &&
          latestVersion != null) {
        return;
      }
    }

    phase = FwUpdatePhase.checking;
    errorMessage = null;
    notifyListeners();

    try {
      final release = await _fetchLatestAppRelease();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsCheckAt, DateTime.now().millisecondsSinceEpoch);

      if (release == null) {
        phase = FwUpdatePhase.idle;
        notifyListeners();
        return;
      }

      latestVersion = release.version;
      latestSha256 = release.sha256;
      latestApkUrl = release.apkUrl;
      latestTag = release.tag;
      bytesTotal = release.sizeBytes;

      await prefs.setString(_prefsLatest, release.version);
      await prefs.setString(_prefsSha, release.sha256);
      await prefs.setString(_prefsApkUrl, release.apkUrl);
      await prefs.setString(_prefsTag, release.tag);
      await prefs.setInt(_prefsSize, release.sizeBytes);

      if (cachedApkPath != null) {
        final f = File(cachedApkPath!);
        if (await f.exists()) {
          final digest = sha256.convert(await f.readAsBytes()).toString();
          if (digest != release.sha256) {
            cachedApkPath = null;
            await prefs.remove(_prefsApkPath);
          }
        }
      }

      phase = FwUpdatePhase.idle;
      notifyListeners();
    } catch (e) {
      AppLog.w('update', 'App update check failed: $e');
      errorMessage = 'Couldn’t check for app updates';
      phase = FwUpdatePhase.error;
      notifyListeners();
      phase = FwUpdatePhase.idle;
      notifyListeners();
    }
  }

  Future<String> ensureApkDownloaded() async {
    if (latestSha256 == null || latestApkUrl == null || latestVersion == null) {
      throw StateError('No release cached — check for updates first');
    }
    if (cachedApkPath != null) {
      final f = File(cachedApkPath!);
      if (await f.exists()) {
        final bytes = await f.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        if (digest == latestSha256) {
          return f.path;
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
      final req = http.Request('GET', Uri.parse(latestApkUrl!));
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
          eta = Duration(seconds: left.clamp(1, 1200).round());
        }
        notifyListeners();
      }
      final bytes = Uint8List.fromList(chunks);
      final digest = sha256.convert(bytes).toString();
      if (digest != latestSha256) {
        throw StateError('The update download was damaged. Try again.');
      }
      final dir = await getApplicationSupportDirectory();
      final outDir = Directory(p.join(dir.path, 'updates'));
      await outDir.create(recursive: true);
      final safeVer = latestVersion!.replaceAll(
        RegExp(r'[^0-9a-zA-Z._-]'),
        '_',
      );
      final out = File(p.join(outDir.path, 'TankLink-$safeVer.apk'));
      await out.writeAsBytes(bytes, flush: true);
      cachedApkPath = out.path;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsApkPath, out.path);
      phase = FwUpdatePhase.idle;
      notifyListeners();
      return out.path;
    } catch (e) {
      AppLog.e('update', 'Download failed', e);
      errorMessage = e.toString();
      phase = FwUpdatePhase.error;
      notifyListeners();
      rethrow;
    } finally {
      client.close();
    }
  }

  void setDone() {
    phase = FwUpdatePhase.done;
    notifyListeners();
  }

  void setError(String message) {
    AppLog.e('update', 'App update failed', message);
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

  Future<AppReleaseInfo?> _fetchLatestAppRelease() async {
    final list = await fetchGitHubReleases(owner: repoOwner, repo: repoName);
    final candidates = listTaggedReleasesBySemver(
      releases: list,
      tagPrefix: 'app-v',
      binAssetName: apkAssetName,
      manifestAssetName: 'app-manifest.json',
    );
    for (final c in candidates) {
      final man = await fetchReleaseManifest(c.manifestUrl);
      if (man == null) continue;
      if (man['component'] != 'tanklink_app') continue;
      final sha = (man['sha256'] as String?)?.toLowerCase();
      final manVer = man['version'] as String? ?? c.tagVersion;
      if (sha == null || sha.length != 64) continue;
      if (SemVer.tryParse(manVer) == null) continue;
      return AppReleaseInfo(
        version: manVer,
        tag: c.tag,
        apkUrl: c.binUrl,
        manifestUrl: c.manifestUrl,
        sha256: sha,
        sizeBytes: c.sizeBytes,
      );
    }
    return null;
  }
}
