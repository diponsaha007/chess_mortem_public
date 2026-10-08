import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:multistockfish/multistockfish.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_log.dart';

/// Stockfish 18's two neural nets (~80 MB): where they live, whether they
/// are there, and how to download them. Directory and client are injectable
/// for tests.
class NnueAssets {
  NnueAssets({
    http.Client? client,
    Future<Directory> Function()? directory,
    String? bigNet,
    String? smallNet,
  }) : _client = client ?? http.Client(),
       _directory = directory ?? getApplicationSupportDirectory,
       bigNetName = bigNet ?? Stockfish.latestBigNNUE,
       smallNetName = smallNet ?? Stockfish.latestSmallNNUE;

  final http.Client _client;
  final Future<Directory> Function() _directory;

  /// Default to the plugin's own filenames; overridable for tests.
  final String bigNetName;
  final String smallNetName;

  /// The small net's share of the progress bar (~5 MB of ~80).
  static const _smallNetShare = 0.06;

  /// Stockfish's net server; it redirects to a CDN.
  static Uri urlFor(String name) =>
      Uri.parse('https://tests.stockfishchess.org/api/nn/$name');

  /// `nn-37f18f62d772.nnue` hashes (SHA-256) to a digest starting with those
  /// digits — the only integrity check that means anything.
  static String expectedDigestPrefix(String name) =>
      name.replaceAll('nn-', '').replaceAll('.nnue', '');

  Future<String> pathFor(String name) async =>
      '${(await _directory()).path}/$name';

  Future<String> get bigNetPath => pathFor(bigNetName);
  Future<String> get smallNetPath => pathFor(smallNetName);

  /// Both nets fully downloaded. Partial files live under `.part` names.
  Future<bool> get isReady async {
    for (final name in [bigNetName, smallNetName]) {
      if (!await File(await pathFor(name)).exists()) return false;
    }
    return true;
  }

  /// Fetches both nets, reporting 0.0-1.0. Throws on failure, leaving
  /// nothing [isReady] would accept.
  Future<void> download({void Function(double progress)? onProgress}) async {
    await _fetch(
      smallNetName,
      onProgress: (f) => onProgress?.call(f * _smallNetShare),
    );
    await _fetch(
      bigNetName,
      onProgress: (f) =>
          onProgress?.call(_smallNetShare + f * (1 - _smallNetShare)),
    );
    onProgress?.call(1);
  }

  /// Removes both nets.
  Future<void> delete() async {
    for (final name in [bigNetName, smallNetName]) {
      final file = File(await pathFor(name));
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _fetch(
    String name, {
    required void Function(double) onProgress,
  }) async {
    final target = File(await pathFor(name));
    if (await target.exists()) {
      onProgress(1);
      return;
    }

    final partial = File('${target.path}.part');
    AppLog.instance.info('nets', 'downloading $name');

    final response = await _client.send(http.Request('GET', urlFor(name)));
    if (response.statusCode != 200) {
      throw HttpException(
        'Could not download $name — the server answered '
        'HTTP ${response.statusCode}',
        uri: urlFor(name),
      );
    }

    // Progress hint only: Content-Length is the gzipped size, and more bytes
    // arrive than it says.
    final announced = response.contentLength;
    var received = 0;
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);

    final sink = partial.openWrite();
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (announced != null && announced > 0) {
          onProgress((received / announced).clamp(0, 1));
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
      hasher.close();
    }

    await _verify(name, partial, digest.value, received);
    await partial.rename(target.path);
    AppLog.instance.info('nets', 'saved $name ($received bytes)');
    onProgress(1);
  }

  /// The file must hash to its own name: catches truncation, captive portals
  /// and corruption.
  Future<void> _verify(
    String name,
    File partial,
    Digest? digest,
    int received,
  ) async {
    final expected = expectedDigestPrefix(name);
    final actual = digest?.toString() ?? '';
    if (actual.startsWith(expected)) return;

    await partial.delete();
    AppLog.instance.error(
      'nets',
      '$name failed verification: $received bytes hashing to '
          '${actual.isEmpty ? '(nothing)' : actual.substring(0, 12)}, '
          'expected $expected',
    );
    throw HttpException(
      'The downloaded $name is not the file it should be '
      '($received bytes). It may have been cut short.',
      uri: urlFor(name),
    );
  }

  void dispose() => _client.close();
}

/// Catches the one [Digest] a chunked sha256 conversion emits at close.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
