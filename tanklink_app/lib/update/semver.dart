class SemVer implements Comparable<SemVer> {
  SemVer(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static SemVer? tryParse(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return null;
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(cleaned);
    if (m == null) return null;
    return SemVer(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
  }

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(SemVer other) => compareTo(other) > 0;
  bool operator <(SemVer other) => compareTo(other) < 0;

  @override
  String toString() => '$major.$minor.$patch';
}
