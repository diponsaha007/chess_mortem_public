import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// In-memory [FlutterSecureStorage]. Only `read`/`write` are overridden —
/// the only calls the store makes — so anything else fails loudly.
class FakeSecureStorage extends FlutterSecureStorage {
  FakeSecureStorage([Map<String, String>? initial])
    : values = {...?initial},
      super();

  final Map<String, String> values;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
