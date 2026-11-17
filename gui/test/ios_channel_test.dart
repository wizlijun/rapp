import 'package:flutter_test/flutter_test.dart';
import 'package:rapp/ios_channel.dart';

void main() {
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
