// Sign-in answer and update-URL pinning.

import 'package:flutter_test/flutter_test.dart';
import 'package:tanklink/ble/protocol.dart';
import 'package:tanklink/update/github_release_util.dart';

String hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('authResponse matches the firmware', () {
    // Same vector as tl_auth_response in
    // components/tanklink_lora/tanklink_crypto.c (checked on the host).
    final token = List<int>.generate(16, (i) => i);
    final nonce = List<int>.generate(16, (i) => 16 + i);
    expect(hex(authResponse(token, nonce)), 'f7ccfa50b805d56535c5862cd478bf79');
  });

  test('authResponse refuses a short nonce', () {
    expect(
      () => authResponse(List.filled(16, 1), [1, 2, 3]),
      throwsArgumentError,
    );
  });

  Map<String, dynamic> release(String tag, String binUrl) => {
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
    'assets': [
      {'name': 'pump_node.bin', 'browser_download_url': binUrl, 'size': 10},
      {
        'name': 'firmware-manifest.json',
        'browser_download_url':
            'https://github.com/madhukartemba/tanklink/releases/download/$tag/firmware-manifest.json',
      },
    ],
  };

  test('only this repo\'s release downloads are used', () {
    final list = listTaggedReleasesBySemver(
      releases: [
        release(
          'pump-v1.0.0',
          'https://github.com/madhukartemba/tanklink/releases/download/pump-v1.0.0/pump_node.bin',
        ),
        release('pump-v2.0.0', 'https://evil.example/pump_node.bin'),
        release(
          'pump-v3.0.0',
          'https://github.com/someone/else/releases/download/pump-v3.0.0/pump_node.bin',
        ),
      ],
      tagPrefix: 'pump-v',
      binAssetName: 'pump_node.bin',
      manifestAssetName: 'firmware-manifest.json',
    );
    expect(list.map((r) => r.tag), ['pump-v1.0.0']);
  });
}
