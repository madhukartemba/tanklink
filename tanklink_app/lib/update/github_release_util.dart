import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../diag/app_log.dart';
import 'semver.dart';

const githubRequestTimeout = Duration(seconds: 25);

const githubApiHeaders = {
  'Accept': 'application/vnd.github+json',
  'User-Agent': 'TankLink-App',
};

/// True if [candidate] is a newer semver than [currentBest] (or [currentBest] is null).
bool isNewerReleaseVersion(String candidate, String? currentBest) {
  final c = SemVer.tryParse(candidate);
  if (c == null) return false;
  if (currentBest == null) return true;
  final b = SemVer.tryParse(currentBest);
  if (b == null) return true;
  return c > b;
}

/// One GitHub release with the binary and manifest asset URLs we need.
class TaggedReleaseAssets {
  TaggedReleaseAssets({
    required this.tag,
    required this.tagVersion,
    required this.binUrl,
    required this.manifestUrl,
    required this.sizeBytes,
  });

  final String tag;
  final String tagVersion;
  final String binUrl;
  final String manifestUrl;
  final int sizeBytes;
}

/// How often the app looks for updates while it is open. A check younger
/// than [updateRecheckAfter] is reused (a minute less than the interval, so
/// a timer tick never lands just short of it).
const updateCheckInterval = Duration(minutes: 15);
const updateRecheckAfter = Duration(minutes: 14);

/// GitHub refused because this connection used up its hourly allowance
/// (60 calls an hour for apps that don't sign in, shared by everything on
/// the same internet connection).
class GitHubRateLimitException implements Exception {
  GitHubRateLimitException(this.resetAt);
  final DateTime? resetAt;

  String get message {
    final reset = resetAt;
    if (reset == null) return 'Update check limit reached. Try again later.';
    final mins = reset.difference(DateTime.now()).inMinutes + 1;
    return mins <= 1
        ? 'Update check limit reached. Try again in a minute.'
        : 'Update check limit reached. Try again in $mins min.';
  }

  @override
  String toString() => message;
}

Future<List<dynamic>>? _releasesInFlight;
DateTime? _releasesAt;
List<dynamic>? _releases;

/// The repo's release list, from the release service ([releasesServiceUrl])
/// or else GitHub. Pump, tank and app checks all use it, so:
/// - calls within a minute of each other share one request;
/// - the last list and its ETag are saved, and GitHub is asked "changed
///   since?" (saves data; for apps that don't sign in, a 304 still counts
///   against the hourly limit, checked 2026-11-19);
/// - when GitHub refuses (limit reached), the saved list is used instead.
Future<List<dynamic>> fetchGitHubReleases({
  required String owner,
  required String repo,
  int perPage = 30,
}) {
  final recent = _releases;
  final at = _releasesAt;
  if (recent != null &&
      at != null &&
      DateTime.now().difference(at) < const Duration(minutes: 1)) {
    return Future.value(recent);
  }
  return _releasesInFlight ??= _fetchReleases(owner, repo, perPage)
      .then((list) {
        _releases = list;
        _releasesAt = DateTime.now();
        return list;
      })
      .whenComplete(() => _releasesInFlight = null);
}

/// The report service (`report_worker/`) serves this repo's release list,
/// cached, so phones don't each use GitHub's hourly allowance. GitHub is
/// asked directly only when it can't be reached.
const releasesServiceUrl = 'https://tanklink.madhukartemba.in/v1/releases';
const _releasesServiceRepo = 'madhukartemba/tanklink';

Future<List<dynamic>> _fetchReleases(
  String owner,
  String repo,
  int perPage,
) async {
  final cache = await _ReleaseCache.open(owner, repo);
  final saved = await cache.read();
  Map<String, String> headers() => {
    ...githubApiHeaders,
    if (saved != null) 'If-None-Match': saved.etag,
  };

  Future<List<dynamic>?> accept(http.Response res) async {
    if (res.statusCode == 304 && saved != null) {
      return jsonDecode(saved.body) as List<dynamic>;
    }
    if (res.statusCode == 200) {
      final etag = res.headers['etag'];
      if (etag != null && etag.isNotEmpty) await cache.write(etag, res.body);
      return jsonDecode(res.body) as List<dynamic>;
    }
    return null;
  }

  if ('$owner/$repo' == _releasesServiceRepo) {
    try {
      final res = await http
          .get(Uri.parse(releasesServiceUrl), headers: headers())
          .timeout(const Duration(seconds: 15));
      final list = await accept(res);
      if (list != null) return list;
      AppLog.w('update', 'Release service answered ${res.statusCode}');
    } catch (e) {
      AppLog.w('update', 'Release service unreachable: $e');
    }
  }

  final res = await http
      .get(
        Uri.parse(
          'https://api.github.com/repos/$owner/$repo/releases?per_page=$perPage',
        ),
        headers: headers(),
      )
      .timeout(githubRequestTimeout);
  final list = await accept(res);
  if (list != null) return list;
  final limited =
      (res.statusCode == 403 || res.statusCode == 429) &&
      res.headers['x-ratelimit-remaining'] == '0';
  if (limited) {
    AppLog.w('update', 'GitHub rate limit reached');
    if (saved != null) return jsonDecode(saved.body) as List<dynamic>;
    final reset = int.tryParse(res.headers['x-ratelimit-reset'] ?? '');
    throw GitHubRateLimitException(
      reset == null ? null : DateTime.fromMillisecondsSinceEpoch(reset * 1000),
    );
  }
  throw StateError('GitHub API ${res.statusCode}');
}

/// The last release list and its ETag, in the app support dir.
class _ReleaseCache {
  _ReleaseCache(this._file);
  final File _file;

  static Future<_ReleaseCache> open(String owner, String repo) async {
    final dir = await getApplicationSupportDirectory();
    return _ReleaseCache(
      File(p.join(dir.path, 'releases_${owner}_$repo.json')),
    );
  }

  Future<({String etag, String body})?> read() async {
    try {
      if (!await _file.exists()) return null;
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      return (etag: j['etag'] as String, body: j['body'] as String);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String etag, String body) async {
    try {
      await _file.writeAsString(jsonEncode({'etag': etag, 'body': body}));
    } catch (_) {}
  }
}

/// Highest semver among releases whose tag starts with [tagPrefix] and includes both assets.
List<TaggedReleaseAssets> listTaggedReleasesBySemver({
  required List<dynamic> releases,
  required String tagPrefix,
  required String binAssetName,
  required String manifestAssetName,
  String repo = _releasesServiceRepo,
}) {
  final out = <TaggedReleaseAssets>[];
  for (final item in releases) {
    final map = item as Map<String, dynamic>;
    if (map['draft'] == true || map['prerelease'] == true) continue;
    final tag = map['tag_name'] as String? ?? '';
    if (!tag.startsWith(tagPrefix)) continue;
    final tagVersion = tag.substring(tagPrefix.length);
    if (SemVer.tryParse(tagVersion) == null) continue;
    final assets = (map['assets'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    String? binUrl;
    String? manifestUrl;
    var size = 0;
    for (final a in assets) {
      final name = a['name'] as String? ?? '';
      final url = a['browser_download_url'] as String?;
      // Only this repo's own release downloads, whoever served the list (the
      // report service or GitHub). Firmware is also signed and the APK must
      // match the installed app's signer; this is one more check.
      if (url == null || url != releaseDownloadUrl(repo, tag, name)) continue;
      if (name == binAssetName) {
        binUrl = url;
        size = a['size'] as int? ?? 0;
      } else if (name == manifestAssetName) {
        manifestUrl = url;
      }
    }
    if (binUrl == null || manifestUrl == null) continue;
    out.add(
      TaggedReleaseAssets(
        tag: tag,
        tagVersion: tagVersion,
        binUrl: binUrl,
        manifestUrl: manifestUrl,
        sizeBytes: size,
      ),
    );
  }
  out.sort((a, b) {
    final av = SemVer.tryParse(a.tagVersion)!;
    final bv = SemVer.tryParse(b.tagVersion)!;
    return bv.compareTo(av);
  });
  return out;
}

/// The only download URL the app accepts for [name] in release [tag].
String releaseDownloadUrl(String repo, String tag, String name) =>
    'https://github.com/$repo/releases/download/${Uri.encodeComponent(tag)}/'
    '${Uri.encodeComponent(name)}';

Future<Map<String, dynamic>?> fetchReleaseManifest(String manifestUrl) async {
  final manRes = await http
      .get(Uri.parse(manifestUrl), headers: {'User-Agent': 'TankLink-App'})
      .timeout(githubRequestTimeout);
  if (manRes.statusCode != 200) return null;
  final man = jsonDecode(manRes.body);
  if (man is! Map<String, dynamic>) return null;
  return man;
}
