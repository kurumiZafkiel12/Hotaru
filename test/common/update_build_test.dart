import 'package:hotaru/common/request.dart';
import 'package:hotaru/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _ReleaseRequest extends Request {
  _ReleaseRequest(this.tag);
  final String tag;

  @override
  Future<Map<String, dynamic>> latestRelease() async => {'tag_name': tag};
}

void main() {
  test('current build does not offer itself as an update', () async {
    PackageInfo? previous;
    try {
      previous = globalState.packageInfo;
    } catch (_) {}
    addTearDown(() {
      if (previous != null) globalState.packageInfo = previous;
    });
    globalState.packageInfo = PackageInfo(
      appName: 'Hotaru',
      packageName: 'dev.hotaru.hotaru',
      version: '0.5.0',
      buildNumber: '8',
    );
    expect(await _ReleaseRequest('v0.5.0+8').checkForUpdate(), isNull);
    expect(await _ReleaseRequest('v0.5.0+9').checkForUpdate(), isNotNull);
    expect(await _ReleaseRequest('v0.5.1').checkForUpdate(), isNotNull);
  });
}
