import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ios_channel.dart';
import 'package:rapp/ui/fullscreen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('IosFullscreen: the channel first, then the state and a change; and back', () async {
    const channel = MethodChannel('test/ios');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return true;
    });
    addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final fs = IosFullscreen(IosChannel(channel));
    final seen = <bool>[];
    final sub = fs.changes.listen(seen.add);
    addTearDown(sub.cancel);
    expect(await fs.isFullScreen(), isFalse);

    await fs.setFullScreen(true);
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => [c.method, c.arguments]), [
      ['fullscreen', {'on': true}],
    ]);
    expect(seen, [true]);
    expect(await fs.isFullScreen(), isTrue);

    await fs.setFullScreen(false);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.arguments, {'on': false});
    expect(seen, [true, false]);
    expect(await fs.isFullScreen(), isFalse);
  });

  test('only "not connected" blocks the boot; a timeout or an HTTP error lets the hub try', () {
    expect(const IosNet(ok: true, status: 200).blocked, isFalse);
    expect(const IosNet(ok: false, error: 'Error Domain=NSURLErrorDomain Code=-1009 "offline"').blocked, isTrue);
    expect(const IosNet(ok: false, error: 'Error Domain=NSURLErrorDomain Code=-1001 "timed out"').blocked, isFalse);
    expect(const IosNet(ok: false, status: 503).blocked, isFalse);
  });

  test('the data root is Application Support/rapp', () {
    expect(const IosPaths('/a/Library/Application Support', '/a/Documents').dataRoot,
        '/a/Library/Application Support/rapp');
  });
}
