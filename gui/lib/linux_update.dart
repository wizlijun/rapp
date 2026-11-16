// Linux uses the system package manager; the macOS bundle installer never runs here.
import 'dart:convert';
import 'dart:io';

const linuxBuildVersion = String.fromEnvironment(
  'RAPP_VERSION',
  defaultValue: '开发版',
);
const linuxReleasePage = 'https://github.com/wizlijun/rapp/releases';

class LinuxRelease {
  const LinuxRelease(this.version, this.page, this.package, {this.archive});
  final String version;
  final String page;
  final String? package;
  final String? archive;

  bool get hasLinuxAsset => package != null || archive != null;

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
    String? package, archive;
    var packageRevision = -1;
    if (assets is List) {
      final namePattern = RegExp(
        '^rapp-omarchy-${RegExp.escape(version)}-([0-9]+)-x86_64\\.pkg\\.tar\\.zst\$',
      );
      for (final asset in assets) {
        if (asset is! Map || asset['state'] != 'uploaded') continue;
        final name = asset['name'];
        if (name is! String) continue;
        final match = namePattern.firstMatch(name);
        final portable = name == 'rapp-$version-omarchy-x86_64.tar.gz';
        if (match == null && !portable) continue;
        final expected =
            'https://github.com/wizlijun/rapp/releases/download/$tag/$name';
        if (asset['browser_download_url'] != expected) continue;
        if (portable) archive = expected;
        if (match != null) {
          final revision = int.tryParse(match.group(1)!) ?? -1;
          if (revision > packageRevision) {
            packageRevision = revision;
            package = expected;
          }
        }
      }
    }
    return LinuxRelease(
      version,
      'https://github.com/wizlijun/rapp/releases/tag/$tag',
      package,
      archive: archive,
    );
  }
}

/// Numeric release comparison; development builds have no comparable version.
int? compareLinuxVersions(String a, String b) {
  List<int>? parts(String value) {
    if (!RegExp(r'^v?\d+\.\d+\.\d+$').hasMatch(value)) return null;
    final numbers = value
        .replaceFirst(RegExp(r'^v'), '')
        .split('.')
        .map(int.tryParse)
        .toList();
    return numbers.any((n) => n == null) ? null : numbers.cast<int>();
  }

  final aa = parts(a), bb = parts(b);
  if (aa == null || bb == null) return null;
  for (var i = 0; i < 3; i++) {
    final order = aa[i].compareTo(bb[i]);
    if (order != 0) return order;
  }
  return 0;
}

/// Releases are shared by platforms: a newer Mac release must not hide Linux assets.
/// Scan every page before choosing by version, as old releases can be published late.
Future<LinuxRelease> findLinuxRelease({
  required Future<Object?> Function(int page) fetchPage,
  int pageSize = 100,
  int maxPages = 10,
}) async {
  LinuxRelease? newest, linux;
  for (var page = 1; page <= maxPages; page++) {
    final batch = await fetchPage(page);
    if (batch is! List) throw const FormatException('发布列表无效');
    for (final value in batch) {
      LinuxRelease candidate;
      try {
        candidate = LinuxRelease.fromJson(value);
      } on FormatException {
        continue; // Drafts, prereleases and unrelated tags are not installable releases.
      }
      if (compareLinuxVersions(candidate.version, candidate.version) == null) {
        continue;
      }
      if (newest == null ||
          compareLinuxVersions(candidate.version, newest.version)! > 0) {
        newest = candidate;
      }
      if (candidate.hasLinuxAsset &&
          (linux == null ||
              compareLinuxVersions(candidate.version, linux.version)! > 0)) {
        linux = candidate;
      }
    }
    if (batch.length < pageSize) {
      final result = linux ?? newest;
      if (result == null) throw const FormatException('没有可用的稳定发布');
      return result;
    }
  }
  // Never present a partial scan as the latest available package.
  throw const FormatException('发布列表未读取完整，请打开发布页面');
}

Future<LinuxRelease> checkLinuxRelease() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    return await findLinuxRelease(
      fetchPage: (page) async {
        final request = await client.getUrl(
          Uri.https('api.github.com', '/repos/wizlijun/rapp/releases', {
            'per_page': '100',
            'page': '$page',
          }),
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
        return jsonDecode(utf8.decode(bytes));
      },
    ).timeout(const Duration(seconds: 30));
  } finally {
    client.close(force: true);
  }
}
