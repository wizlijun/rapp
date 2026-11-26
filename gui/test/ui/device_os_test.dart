import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/device_os.dart';

void main() {
  test('wire values map, anything else is unknown', () {
    expect(parseOs('macos'), DeviceOs.macos);
    expect(parseOs('windows'), DeviceOs.windows);
    expect(parseOs('omarchy'), DeviceOs.omarchy);
    expect(parseOs('linux'), DeviceOs.linux);
    expect(parseOs('ipados'), DeviceOs.ipad);
    expect(parseOs('ios'), DeviceOs.iphone);
    expect(parseOs('android-tablet'), DeviceOs.androidTablet);
    expect(parseOs('android'), DeviceOs.androidPhone);
    for (final w in [null, '', 'freebsd', 'MACOS']) {
      expect(parseOs(w), DeviceOs.unknown, reason: '$w');
    }
  });

  test('words', () {
    expect(DeviceOs.values.map(osWord),
        ['macOS', 'Windows', 'Omarchy', 'Linux', 'iPad', 'iPhone', 'Android 平板', 'Android 手机', '系统未知']);
  });

  test('this device', () {
    bool none(String _) => false;
    expect(localDeviceOs(os: 'macos', exists: none), DeviceOs.macos);
    expect(localDeviceOs(os: 'windows', exists: none), DeviceOs.windows);
    expect(localDeviceOs(os: 'linux', exists: none), DeviceOs.linux);
    expect(localDeviceOs(os: 'linux', exists: (p) => p == '/usr/share/omarchy/shell'), DeviceOs.omarchy);
    expect(localDeviceOs(os: 'ios', exists: none, iosIdiom: 'pad'), DeviceOs.ipad);
    expect(localDeviceOs(os: 'ios', exists: none, iosIdiom: 'phone'), DeviceOs.iphone);
    expect(localDeviceOs(os: 'ios', exists: none), DeviceOs.unknown);
    expect(localDeviceOs(os: 'android', exists: none, shortestSide: 800), DeviceOs.androidTablet);
    expect(localDeviceOs(os: 'android', exists: none, shortestSide: 400), DeviceOs.androidPhone);
    expect(localDeviceOs(os: 'fuchsia', exists: none), DeviceOs.unknown);
  });
}
