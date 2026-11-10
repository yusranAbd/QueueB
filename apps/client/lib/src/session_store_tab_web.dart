import 'dart:js_interop';

import 'session_store.dart';

@JS('sessionStorage')
external _Storage get _sessionStorage;

extension type _Storage(JSObject _) implements JSObject {
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

class _BrowserTabStorage implements TabStorage {
  _BrowserTabStorage(this._storage);
  final _Storage _storage;
  @override
  String? getItem(String key) => _storage.getItem(key);
  @override
  void setItem(String key, String value) => _storage.setItem(key, value);
  @override
  void removeItem(String key) => _storage.removeItem(key);
}

/// Null when sessionStorage is blocked or unusable; the app then keeps the
/// session in memory only instead of failing login.
TabStorage? browserTabStorage() {
  try {
    final storage = _sessionStorage;
    const probe = 'queueb.session.probe';
    storage.setItem(probe, '1');
    final usable = storage.getItem(probe) == '1';
    storage.removeItem(probe);
    return usable ? _BrowserTabStorage(storage) : null;
  } catch (_) {
    return null;
  }
}
