import 'semver.dart';

/// True if [candidate] is a newer semver than [currentBest] (or [currentBest] is null).
bool isNewerReleaseVersion(String candidate, String? currentBest) {
  final c = SemVer.tryParse(candidate);
  if (c == null) return false;
  if (currentBest == null) return true;
  final b = SemVer.tryParse(currentBest);
  if (b == null) return true;
  return c > b;
}