import 'dart:async';

import '../api.dart';
import 'push_messaging.dart';

/// Mendaftarkan token FCM untuk akun pasien (peran USER) yang sedang login.
///
/// Token terikat ke sesi di server. Kalau penghapusan saat logout gagal,
/// pencabutan sesi tetap menghentikan push. Peran staf dan dokter tidak
/// didaftarkan.
class PushRegistrar {
  PushRegistrar({
    required this.api,
    required this.messaging,
    this.requestTimeout = const Duration(seconds: 3),
  });

  final QueueApi api;
  final PushMessaging messaging;
  final Duration requestTimeout;

  bool _started = false, _available = false, _disposed = false;
  String? _attemptedUserId, _token;
  Future<void>? _registering;
  StreamSubscription<String>? _tokenRefresh;

  bool get available => _available;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      _available = await messaging.initialize(
        onTap: (tap) {
          if (!_disposed) api.pushTap.value = tap;
        },
      );
    } catch (_) {
      _available = false;
    }
    if (!_available || _disposed) return;
    api.beforeLogout = unregister;
    api.addListener(_sessionChanged);
    _tokenRefresh = messaging.onTokenRefresh.listen(_tokenRefreshed);
    _sessionChanged();
  }

  String? get _patientId {
    final user = api.user;
    if (api.sessionPhase != SessionPhase.ready ||
        api.accessToken == null ||
        user == null ||
        user['peran'] != 'USER') {
      return null;
    }
    final id = user['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  void _sessionChanged() {
    if (_disposed) return;
    if (api.user == null) {
      _attemptedUserId = null;
      _token = null;
      return;
    }
    final userId = _patientId;
    if (userId == null || userId == _attemptedUserId || _registering != null) {
      return;
    }
    // Satu percobaan per login; kegagalan tidak memicu loop ulang.
    _attemptedUserId = userId;
    _registering = _register(userId).whenComplete(() => _registering = null);
  }

  Future<void> _register(String userId) async {
    try {
      // Izin ditolak tidak menghalangi pendaftaran: bila pengguna mengizinkan
      // lewat Pengaturan nanti, token yang sama langsung dapat menerima push.
      await messaging.requestPermission().catchError((Object _) => false);
      final token = await messaging.getToken();
      if (token == null || token.isEmpty || _patientId != userId) return;
      await _put(token);
      if (_patientId == userId) _token = token;
    } catch (_) {
      // Push bersifat best effort; inbox dalam aplikasi tetap tersedia.
    }
  }

  void _tokenRefreshed(String token) {
    final userId = _patientId;
    if (userId == null || userId != _attemptedUserId || token.isEmpty) return;
    _token = token;
    unawaited(_put(token).catchError((Object _) {}));
  }

  Future<void> _put(String token) => api
      .request(
        'PUT',
        '/perangkat-push',
        body: {'token': token, 'platform': 'ANDROID'},
      )
      .timeout(requestTimeout);

  /// Dipanggil QueueApi sebelum logout selagi access token masih berlaku.
  Future<void> unregister() async {
    final token = _token;
    _token = null;
    _attemptedUserId = null;
    if (token != null && _patientId != null) {
      try {
        await api
            .request('DELETE', '/perangkat-push', body: {'token': token})
            .timeout(requestTimeout);
      } catch (_) {
        // Sesi yang dicabut saat logout tetap menghentikan push di server.
      }
    }
    // Token baru dibuat saat login berikutnya; jangan menahan logout.
    unawaited(messaging.deleteToken().catchError((Object _) {}));
  }

  void dispose() {
    _disposed = true;
    if (api.beforeLogout == unregister) api.beforeLogout = null;
    api.removeListener(_sessionChanged);
    unawaited(_tokenRefresh?.cancel());
  }
}
