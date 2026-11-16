import 'dart:convert';

/// Data notifikasi yang diketuk pengguna (bagian `data` pesan FCM).
class PushTap {
  const PushTap({this.notifikasiId, this.tiketAntreanId});

  factory PushTap.fromData(Map<String, dynamic> data) => PushTap(
    notifikasiId: _text(data['notifikasiId']),
    tiketAntreanId: _text(data['tiketAntreanId']),
  );

  factory PushTap.fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return const PushTap();
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) return PushTap.fromData(decoded);
    } on FormatException {
      // Payload asing diabaikan; tap tetap membuka inbox.
    }
    return const PushTap();
  }

  final String? notifikasiId, tiketAntreanId;

  static String? _text(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

typedef PushTapHandler = void Function(PushTap tap);

/// Batas platform push agar logika pendaftaran dapat diuji tanpa Firebase.
abstract class PushMessaging {
  /// Menyiapkan Firebase dan kanal notifikasi. `false` berarti push tidak
  /// tersedia (Web, belum ada google-services.json, atau inisialisasi gagal).
  Future<bool> initialize({required PushTapHandler onTap});

  /// `true` bila pengguna mengizinkan notifikasi.
  Future<bool> requestPermission();

  Future<String?> getToken();

  Stream<String> get onTokenRefresh;

  Future<void> deleteToken();
}

/// Implementasi kosong untuk Web, desktop, dan pengujian.
class DisabledPushMessaging implements PushMessaging {
  const DisabledPushMessaging();

  @override
  Future<bool> initialize({required PushTapHandler onTap}) async => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<String?> getToken() async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream.empty();

  @override
  Future<void> deleteToken() async {}
}
