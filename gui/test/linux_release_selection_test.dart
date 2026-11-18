import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ui/tokens.dart';
import 'package:rapp/linux_update.dart';
import 'package:rapp/pages/linux_update_section.dart';

Map<String, Object?> release(
  String version, {
  bool linux = true,
  bool portable = false,
  bool prerelease = false,
}) {
  final name = portable
      ? 'rapp-$version-omarchy-x86_64.tar.gz'
      : 'rapp-omarchy-$version-1-x86_64.pkg.tar.zst';
  return {
    'tag_name': 'v$version',
    'prerelease': prerelease,
    'assets': <Map<String, Object?>>[
      if (linux)
        {
          'name': name,
          'state': 'uploaded',
          'browser_download_url':
              'https://github.com/wizlijun/rapp/releases/download/v$version/$name',
        },
    ],
  };
}

void main() {
  test(
    'walks pages past Mac-only releases and compares versions numerically',
    () async {
      final pages = <int>[];
      final result = await findLinuxRelease(
        pageSize: 2,
        fetchPage: (page) async {
          pages.add(page);
          return switch (page) {
            1 => [release('0.13.0', linux: false), release('0.9.0')],
            2 => [release('0.12.2'), release('0.14.0', prerelease: true)],
            _ => [],
          };
        },
      );
      expect(pages, [1, 2, 3]);
      expect(result.version, '0.12.2');
      expect(result.package, contains('rapp-omarchy-0.12.2-1-x86_64'));
    },
  );
  test('portable-only release is available and package revisions are deterministic', () async {
    final portable = await findLinuxRelease(
      fetchPage: (_) async => [release('0.12.2', portable: true)],
    );
    expect(portable.package, isNull);
    expect(portable.archive, endsWith('rapp-0.12.2-omarchy-x86_64.tar.gz'));
    final value = release('0.12.2');
    final assets = value['assets'] as List;
    final base = Map<String, Object?>.from(assets.first as Map);
    for (final revision in [3, 2]) {
      assets.add({
        for (final e in base.entries)
          e.key: e.value is String
              ? (e.value as String).replaceAll('-1-x86_64', '-$revision-x86_64')
              : e.value,
      });
    }
    expect(LinuxRelease.fromJson(value).package, contains('-3-x86_64'));
  });
  test(
    'missing assets reported, incomplete pages and malformed lists fail',
    () async {
      final result = await findLinuxRelease(
        fetchPage: (_) async => [release('0.12.2', linux: false)],
      );
      expect(result.hasLinuxAsset, isFalse);
      await expectLater(
        findLinuxRelease(fetchPage: (_) async => {'error': 'bad'}),
        throwsFormatException,
      );
      await expectLater(
        findLinuxRelease(
          pageSize: 1,
          maxPages: 2,
          fetchPage: (_) async => [release('0.12.2')],
        ),
        throwsFormatException,
      );
      await expectLater(
        findLinuxRelease(fetchPage: (_) async => []),
        throwsFormatException,
      );
      await expectLater(
        findLinuxRelease(fetchPage: (_) async => throw Exception('offline')),
        throwsException,
      );
    },
  );
  test('foreign URLs cannot become portable downloads', () {
    final value = release('0.12.2', portable: true);
    final asset = (value['assets'] as List).first as Map;
    asset['browser_download_url'] = 'https://elsewhere.invalid/file.tar.gz';
    expect(LinuxRelease.fromJson(value).hasLinuxAsset, isFalse);
    expect(compareLinuxVersions('0.12.2', '0.9.9'), greaterThan(0));
    expect(compareLinuxVersions('开发版', '0.12.2'), isNull);
  });
  testWidgets('older Linux package is not offered as an update', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: themeDataFor(RappTheme.matrix), 
        home: Scaffold(
          body: LinuxUpdateSection(
            version: '0.12.2',
            check: () async => LinuxRelease.fromJson(release('0.5.2')),
            openPage: (_) async {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无需降级'), findsOneWidget);
    expect(find.text('下载 Linux 安装包'), findsNothing);
  });
  testWidgets('portable release has its own download button', (tester) async {
    final opened = <String>[];
    final asset = LinuxRelease.fromJson(release('0.12.2', portable: true));
    await tester.pumpWidget(
      MaterialApp(theme: themeDataFor(RappTheme.matrix), 
        home: Scaffold(
          body: LinuxUpdateSection(
            version: '0.5.2',
            check: () async => asset,
            openPage: (url) async {
              opened.add(url);
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载 Linux 便携包'));
    await tester.pumpAndSettle();
    expect(opened, [asset.archive]);
    expect(find.text('下载 Linux 安装包'), findsNothing);
  });
}
