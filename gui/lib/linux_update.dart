// Linux uses the system package manager; the macOS bundle installer never runs here.
import 'dart:convert';
import 'dart:io';

const linuxBuildVersion = String.fromEnvironment(
  'RAPP_VERSION',
  defaultValue: '开发版',
);
const linuxReleasePage = 'https://github.com/wizlijun/rapp/releases/latest';

class LinuxRelease {
  const LinuxRelease(this.version, this.page, this.package);
  final String version;
  final String page;
  final String? package;

  factory LinuxRelease.fromJson(Object? value) {
    if (value is! Map ||
        value['draft'] == true ||
        value['prerelease'] == true) {
      throw const FormatException('发布信息无效');
    }
    final tag = value['tag_name'];
    if (tag is! String || !RegExp(r'^v?\d+\.\d+\.\d+$').hasMatch(tag)) {
      throw const FormatException('发布版本号无效');
    }
    final version = tag.replaceFirst(RegExp(r'^v'), '');
    final assets = value['assets'];
    String? package;
    if (assets is List) {
      final namePattern = RegExp(
        '^rapp-omarchy-${RegExp.escape(version)}-[0-9]+-x86_64\\.pkg\\.tar\\.zst\$',
      );
      for (final asset in assets) {
        if (asset is! Map || asset['state'] != 'uploaded') continue;
        final name = asset['name'];
        if (name is! String || !namePattern.hasMatch(name)) continue;
        final expected =
            'https://github.com/wizlijun/rapp/releases/download/$tag/$name';
        if (asset['browser_download_url'] == expected) package = expected;
      }
    }
    return LinuxRelease(
      version,
      'https://github.com/wizlijun/rapp/releases/tag/$tag',
      package,
    );
  }
}

Future<LinuxRelease> checkLinuxRelease() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await (() async {
      final request = await client.getUrl(
        Uri.https('api.github.com', '/repos/wizlijun/rapp/releases/latest'),
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'rapp-linux');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('检查更新失败（HTTP ${response.statusCode}）');
      }
      final bytes = <int>[];
      await for (final part in response) {
        if (bytes.length + part.length > 2 * 1024 * 1024) {
          throw const FormatException('发布信息过大');
        }
        bytes.addAll(part);
      }
      return LinuxRelease.fromJson(jsonDecode(utf8.decode(bytes)));
    })().timeout(const Duration(seconds: 15));
  } finally {
    client.close(force: true);
  }
}
