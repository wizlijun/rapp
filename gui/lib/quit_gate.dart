/// Runs one confirmation at a time: a request while one is up answers false at once, without
/// showing a second dialog (⌘Q again, the Dock's 退出, the tray, an upgrade's 升级 rapp？).
class OneAtATime {
  bool _busy = false;

  Future<bool> ask(Future<bool> Function() confirm) async {
    if (_busy) return false;
    _busy = true;
    try {
      return await confirm();
    } finally {
      _busy = false;
    }
  }
}
