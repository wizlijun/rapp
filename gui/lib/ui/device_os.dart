// What system a device is, for the mark under its column on the overview (全景). Pure Dart.
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

enum DeviceOs { macos, windows, omarchy, linux, ipad, iphone, androidTablet, androidPhone, unknown }

/// A device's `os` as its service reports it; anything this build does not know is [DeviceOs.unknown].
DeviceOs parseOs(String? wire) => switch (wire) {
      'macos' => DeviceOs.macos,
      'windows' => DeviceOs.windows,
      'omarchy' => DeviceOs.omarchy,
      'linux' => DeviceOs.linux,
      'ipados' => DeviceOs.ipad,
      'ios' => DeviceOs.iphone,
      'android-tablet' => DeviceOs.androidTablet,
      'android' => DeviceOs.androidPhone,
      _ => DeviceOs.unknown,
    };

/// The mark's tooltip and screen-reader word.
String osWord(DeviceOs os) => switch (os) {
      DeviceOs.macos => 'macOS',
      DeviceOs.windows => 'Windows',
      DeviceOs.omarchy => 'Omarchy',
      DeviceOs.linux => 'Linux',
      DeviceOs.ipad => 'iPad',
      DeviceOs.iphone => 'iPhone',
      DeviceOs.androidTablet => 'Android 平板',
      DeviceOs.androidPhone => 'Android 手机',
      DeviceOs.unknown => '系统未知',
    };

/// The path the service also checks: Omarchy is a Linux whose shell config is installed.
const omarchyMarker = '/usr/share/omarchy/shell';

/// This device's own system. iOS needs [iosIdiom] (`pad` / `phone`) from the native side; without it, unknown.
DeviceOs localDeviceOs({String? os, bool Function(String path)? exists, double? shortestSide, String? iosIdiom}) {
  exists ??= (p) => FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound;
  switch (os ?? Platform.operatingSystem) {
    case 'macos':
      return DeviceOs.macos;
    case 'windows':
      return DeviceOs.windows;
    case 'linux':
      return exists(omarchyMarker) ? DeviceOs.omarchy : DeviceOs.linux;
    case 'ios':
      return switch (iosIdiom) { 'pad' => DeviceOs.ipad, 'phone' => DeviceOs.iphone, _ => DeviceOs.unknown };
    case 'android':
      shortestSide ??= _shortestSide();
      return shortestSide >= 600 ? DeviceOs.androidTablet : DeviceOs.androidPhone;
  }
  return DeviceOs.unknown;
}

double _shortestSide() {
  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) return 0;
  final v = views.first;
  return v.physicalSize.shortestSide / v.devicePixelRatio;
}
