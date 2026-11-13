import 'package:flutter/material.dart';

import '../linux_update.dart';

/// Available even with no local hosting service. Installation belongs to pacman.
class LinuxUpdateSection extends StatefulWidget {
  const LinuxUpdateSection({
    super.key,
    required this.openPage,
    this.check = checkLinuxRelease,
    this.version = linuxBuildVersion,
  });
  final Future<void> Function(String) openPage;
  final Future<LinuxRelease> Function() check;
  final String version;

  @override
  State<LinuxUpdateSection> createState() => _LinuxUpdateSectionState();
}

class _LinuxUpdateSectionState extends State<LinuxUpdateSection> {
  bool _busy = false;
  LinuxRelease? _release;
  String? _error;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final release = await widget.check();
      if (mounted) setState(() => _release = release);
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法检查更新，可打开发布页面');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String page) async {
    try {
      await widget.openPage(page);
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开浏览器');
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = _release;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('版本与升级', style: TextStyle(fontWeight: FontWeight.w600)),
        Text('当前 ${widget.version} · Omarchy / Linux'),
        if (_busy) const Text('正在检查'),
        if (release != null)
          Text(
            release.package == null
                ? '${release.version} 尚未提供 Linux 安装包'
                : '最新发布 ${release.version} · 下载后使用系统软件包管理器安装',
          ),
        if (_error != null) Text(_error!),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: _busy ? null : _check,
              child: const Text('检查更新'),
            ),
            OutlinedButton(
              onPressed: () => _open(release?.page ?? linuxReleasePage),
              child: const Text('发布页面'),
            ),
            if (release?.package != null)
              OutlinedButton(
                onPressed: () => _open(release!.package!),
                child: const Text('下载 Linux 安装包'),
              ),
          ],
        ),
      ],
    );
  }
}
