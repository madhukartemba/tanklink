import 'dart:convert';

import 'package:http/http.dart' as http;

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

Future<List<dynamic>> fetchGitHubReleases({
  required String owner,
  required String repo,
  int perPage = 30,
}) async {
  final uri = Uri.parse(
    'https://api.github.com/repos/$owner/$repo/releases?per_page=$perPage',
  );
  final res = await http
      .get(uri, headers: githubApiHeaders)
      .timeout(githubRequestTimeout);
  if (res.statusCode != 200) {
    throw StateError('GitHub API ${res.statusCode}');
  }
  return jsonDecode(res.body) as List<dynamic>;
}

/// Highest semver among releases whose tag starts with [tagPrefix] and includes both assets.
List<TaggedReleaseAssets> listTaggedReleasesBySemver({
  required List<dynamic> releases,
  required String tagPrefix,
  required String binAssetName,
  required String manifestAssetName,
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
      if (url == null) continue;
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

Future<Map<String, dynamic>?> fetchReleaseManifest(String manifestUrl) async {
  final manRes = await http
      .get(Uri.parse(manifestUrl), headers: {'User-Agent': 'TankLink-App'})
      .timeout(githubRequestTimeout);
  if (manRes.statusCode != 200) return null;
  final man = jsonDecode(manRes.body);
  if (man is! Map<String, dynamic>) return null;
  return man;
}
