import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'session_store_tab.dart'
    if (dart.library.js_interop) 'session_store_tab_web.dart';

/// A token pair is one value: rotation must never mix old/new credentials.
class SessionCredentials {
  const SessionCredentials(this.accessToken, this.refreshToken);
  final String accessToken, refreshToken;
  @override
  String toString() => 'SessionCredentials([redacted])';
}

abstract interface class SessionStore {
  Future<SessionCredentials?> read();
  Future<void> write(SessionCredentials credentials);
  Future<void> clear();
}

/// Unsupported platforms (and Web without tab storage) keep tokens in memory.
class MemorySessionStore implements SessionStore {
  SessionCredentials? value;
  @override
  Future<SessionCredentials?> read() async => value;
  @override
  Future<void> write(SessionCredentials credentials) async =>
      value = credentials;
  @override
  Future<void> clear() async => value = null;
}

class AndroidSessionStore implements SessionStore {
  AndroidSessionStore({required this.apiBase, FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'queueb_session',
              resetOnError: false,
            ),
          );
  final String apiBase;
  final FlutterSecureStorage _storage;
  // Isolate API environments; switching API_BASE_URL must not forward old tokens.
  String get _key => 'session.v1.${base64Url.encode(utf8.encode(apiBase))}';
  @override
  Future<SessionCredentials?> read() async {
    try {
      return _decodeSession(await _storage.read(key: _key), apiBase);
    } on FormatException {
      await clear(); // Corrupt credentials cannot authorize a user.
      return null;
    }
  }

  @override
  Future<void> write(SessionCredentials credentials) =>
      _storage.write(key: _key, value: _encodeSession(credentials, apiBase));
  @override
  Future<void> clear() async {
    // A credential-free tombstone prevents resurrection if deletion alone fails.
    try {
      await _storage.write(key: _key, value: '{"loggedOut":true}');
    } catch (_) {
      await _storage.delete(
        key: _key,
      ); // Successful deletion is also sufficient.
      return;
    }
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // Tombstone is durable and contains no credentials.
    }
  }
}

/// Synchronous key-value storage scoped to one browser tab (sessionStorage).
abstract interface class TabStorage {
  String? getItem(String key);
  void setItem(String key, String value);
  void removeItem(String key);
}

/// Web: the token pair survives a reload or a tab restored by the browser, but
/// stays in this tab only and disappears when the tab is closed or on logout.
class TabSessionStore implements SessionStore {
  TabSessionStore({required this.apiBase, required this.storage});
  final String apiBase;
  final TabStorage storage;
  // Isolate API environments; switching API_BASE_URL must not forward old tokens.
  String get _key => 'queueb.session.v1.$apiBase';
  @override
  Future<SessionCredentials?> read() async {
    try {
      return _decodeSession(storage.getItem(_key), apiBase);
    } on FormatException {
      await clear(); // Corrupt credentials cannot authorize a user.
      return null;
    }
  }

  @override
  Future<void> write(SessionCredentials credentials) async {
    final value = _encodeSession(credentials, apiBase);
    storage.setItem(_key, value);
    if (storage.getItem(_key) != value) {
      throw StateError('Sesi tab tidak dapat disimpan.');
    }
  }

  @override
  Future<void> clear() async => storage.removeItem(_key);
}

String _encodeSession(SessionCredentials credentials, String apiBase) =>
    jsonEncode({
      'version': 1,
      'apiBase': apiBase,
      'accessToken': credentials.accessToken,
      'refreshToken': credentials.refreshToken,
    });

/// Returns null for no session or a logout tombstone; throws on corruption.
SessionCredentials? _decodeSession(String? encoded, String apiBase) {
  if (encoded == null) return null;
  final value = jsonDecode(encoded);
  if (value is Map && value['loggedOut'] == true) return null;
  if (value is! Map ||
      value['version'] != 1 ||
      value['apiBase'] != apiBase ||
      value['accessToken'] is! String ||
      value['refreshToken'] is! String ||
      (value['accessToken'] as String).isEmpty ||
      (value['refreshToken'] as String).isEmpty) {
    throw const FormatException('Invalid session envelope');
  }
  return SessionCredentials(
    value['accessToken'] as String,
    value['refreshToken'] as String,
  );
}

SessionStore platformSessionStore(String apiBase) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidSessionStore(apiBase: apiBase);
  }
  final tab = kIsWeb ? browserTabStorage() : null;
  return tab == null
      ? MemorySessionStore()
      : TabSessionStore(apiBase: apiBase, storage: tab);
}
