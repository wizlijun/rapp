import 'package:rapp/paths.dart';
import 'package:flutter/material.dart';
import 'package:rapp/pages/global_sections.dart';
import 'package:rapp/pages/local_section.dart';
import 'package:rapp/service_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/linux_update.dart';
import 'package:rapp/pages/linux_update_section.dart';

void main() {
  const package = 'rapp-omarchy-0.5.0-1-x86_64.pkg.tar.zst';
  const url = 'https://github.com/wizlijun/rapp/releases/download/v0.5.0/$package';
  Map<String, Object?> release({String name = package, String download = url}) => {
    'tag_name': 'v0.5.0', 'draft': false, 'prerelease': false,
    'assets': [{'name': name, 'browser_download_url': download, 'state': 'uploaded'}],
  };
  test('selects the Linux package and rejects macOS, untrusted URLs and prereleases', () {
    expect(LinuxRelease.fromJson(release()).package, url);
    expect(LinuxRelease.fromJson(release(name: 'rapp-0.5.0.pkg')).package, isNull);
    expect(LinuxRelease.fromJson(release(download: 'https://elsewhere.invalid/$package')).package, isNull);
    expect(() => LinuxRelease.fromJson({...release(), 'prerelease': true}), throwsFormatException);
    expect(() => LinuxRelease.fromJson({...release(), 'tag_name': '../bad'}), throwsFormatException);
  });
  testWidgets('Linux update works without a service and opens its own package', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LinuxUpdateSection(
      version: '0.4.1', check: () async => LinuxRelease.fromJson(release()),
      openPage: (page) async => opened.add(page)))));
    expect(find.text('当前 0.4.1 · Omarchy / Linux'), findsOneWidget);
    await tester.tap(find.text('检查更新')); await tester.pumpAndSettle();
    await tester.tap(find.text('下载 Linux 安装包')); await tester.pumpAndSettle();
    expect(opened, [url]);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('立即升级'), findsNothing);
  });
  testWidgets('Linux: 本机 has no macOS permissions and no updates; 全局设置 offers updates with no service', (tester) async {
    final monitor = ServiceMonitor(readToken: () async => 'unused');
    addTearDown(monitor.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: Column(children: [
      LocalSection(platform: TargetPlatform.linux, monitor: monitor, control: null, data: DataDir('/unused')),
      GlobalSections(platform: TargetPlatform.linux, monitor: monitor, data: DataDir('/unused'), openPage: (_) async {}),
    ])))));
    expect(find.descendant(of: find.byType(LocalSection), matching: find.byType(LinuxUpdateSection)), findsNothing);
    expect(find.descendant(of: find.byType(GlobalSections), matching: find.byType(LinuxUpdateSection)), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.textContaining('屏幕录制'), findsNothing);
    expect(find.textContaining('本机为 Linux 控制端'), findsOneWidget);
  });
  testWidgets('missing Linux assets and network failures do not offer macOS installers', (tester) async {
    var fail = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LinuxUpdateSection(
      check: () async {
        if (fail) throw Exception('offline');
        return LinuxRelease.fromJson(release(name: 'rapp-0.5.0.pkg'));
      }, openPage: (_) async {}))));
    await tester.tap(find.text('检查更新')); await tester.pumpAndSettle();
    expect(find.text('0.5.0 尚未提供 Linux 安装包'), findsOneWidget);
    expect(find.text('下载 Linux 安装包'), findsNothing);
    fail = true;
    await tester.tap(find.text('检查更新')); await tester.pumpAndSettle();
    expect(find.text('暂时无法检查更新，可打开发布页面'), findsOneWidget);
  });
}
