import 'dart:convert';
import 'dart:io';

import 'package:chess_mortem/engine/nnue_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The name Stockfish would give these bytes: `nn-` plus the first twelve
/// hex digits of their SHA-256.
String nameFor(List<int> bytes) =>
    'nn-${sha256.convert(bytes).toString().substring(0, 12)}.nnue';

void main() {
  late Directory temp;
  Future<Directory> dir() async => temp;

  final bigBytes = utf8.encode('pretend this is a big neural network');
  final smallBytes = utf8.encode('and this is the small one');

  /// Serves the bytes each net is named after. [claimedLength] misreports
  /// Content-Length the way a compressing CDN does; [status] fakes an error.
  MockClient serving({
    Map<String, List<int>>? bodies,
    int? claimedLength,
    int status = 200,
  }) => MockClient.streaming((request, _) async {
    final name = request.url.pathSegments.last;
    final body =
        (bodies ??
        {nameFor(bigBytes): bigBytes, nameFor(smallBytes): smallBytes})[name]!;
    return http.StreamedResponse(
      Stream.value(body),
      status,
      contentLength: claimedLength ?? body.length,
    );
  });

  NnueAssets assets({
    MockClient? client,
    Map<String, List<int>>? bodies,
    int? claimedLength,
    int status = 200,
  }) => NnueAssets(
    client:
        client ??
        serving(bodies: bodies, claimedLength: claimedLength, status: status),
    directory: dir,
    bigNet: nameFor(bigBytes),
    smallNet: nameFor(smallBytes),
  );

  setUp(() => temp = Directory.systemTemp.createTempSync('nnue_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('downloads from Stockfish\'s net server', () {
    expect(
      NnueAssets.urlFor('nn-abc.nnue').toString(),
      'https://tests.stockfishchess.org/api/nn/nn-abc.nnue',
    );
  });

  test('a net is named after its own hash', () {
    expect(
      NnueAssets.expectedDigestPrefix('nn-37f18f62d772.nnue'),
      '37f18f62d772',
    );
  });

  test('is not ready before anything is downloaded', () async {
    expect(await assets().isReady, isFalse);
  });

  test('a completed download leaves both nets in place', () async {
    final nets = assets();
    await nets.download();

    expect(await nets.isReady, isTrue);
    expect(File(await nets.bigNetPath).readAsBytesSync(), bigBytes);
    expect(File(await nets.smallNetPath).readAsBytesSync(), smallBytes);
  });

  test('reports progress that ends at 1.0', () async {
    final seen = <double>[];
    await assets().download(onProgress: seen.add);

    expect(seen.last, 1.0);
    expect(seen.every((p) => p >= 0 && p <= 1), isTrue);
  });

  test('a compressed response is not mistaken for a failure', () async {
    // The real bug: the CDN gzips the net and the HTTP client decompresses
    // it, so more bytes arrive than Content-Length announced. Comparing the
    // two failed every single download.
    final nets = assets(claimedLength: 3);
    final seen = <double>[];

    await nets.download(onProgress: seen.add);

    expect(await nets.isReady, isTrue);
    // Progress must not run past the end of the bar either.
    expect(seen.every((p) => p <= 1), isTrue);
  });

  test('a file that is not the net it claims to be is rejected', () async {
    final nets = assets(
      bodies: {
        nameFor(bigBytes): utf8.encode('<html>captive portal</html>'),
        nameFor(smallBytes): utf8.encode('<html>captive portal</html>'),
      },
    );

    await expectLater(nets.download(), throwsA(isA<HttpException>()));
    expect(await nets.isReady, isFalse);
    // Nothing half-written is left wearing the real name.
    expect(File(await nets.smallNetPath).existsSync(), isFalse);
  });

  test('an HTTP error leaves the app on the bundled engine', () async {
    final nets = assets(status: 404);

    await expectLater(nets.download(), throwsA(isA<HttpException>()));
    expect(await nets.isReady, isFalse);
  });

  test('deleting the nets makes it not ready again', () async {
    final nets = assets();
    await nets.download();
    expect(await nets.isReady, isTrue);

    await nets.delete();
    expect(await nets.isReady, isFalse);
  });
}
