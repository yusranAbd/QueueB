import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'push_messaging.dart';

PushMessaging createPlatformPushMessaging() => Platform.isAndroid
    ? FirebasePushMessaging()
    : const DisabledPushMessaging();

/// Push FCM Android. Saat aplikasi di latar belakang/tertutup, sistem Android
/// menampilkan notifikasi FCM sendiri; saat di depan, pesan ditampilkan lewat
/// flutter_local_notifications pada kanal yang sama.
class FirebasePushMessaging implements PushMessaging {
  static const _channel = AndroidNotificationChannel(
    'queueb_antrean',
    'Antrean',
    description: 'Panggilan nomor dan perubahan status tiket',
    importance: Importance.high,
  );

  final _local = FlutterLocalNotificationsPlugin();
  FirebaseMessaging? _messaging;
  final _subscriptions = <StreamSubscription<Object?>>[];

  @override
  Future<bool> initialize({required PushTapHandler onTap}) async {
    if (_messaging != null) return true;
    try {
      // Tanpa google-services.json, inisialisasi gagal dan push nonaktif.
      await Firebase.initializeApp();
    } catch (_) {
      return false;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (response) =>
            onTap(PushTap.fromPayload(response.payload)),
      );
      await _local
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_channel);
      _subscriptions
        ..add(FirebaseMessaging.onMessage.listen(_showForeground))
        ..add(
          FirebaseMessaging.onMessageOpenedApp.listen(
            (message) => onTap(PushTap.fromData(message.data)),
          ),
        );
      _messaging = messaging;

      final initial = await messaging.getInitialMessage();
      if (initial != null) onTap(PushTap.fromData(initial.data));
      final launch = await _local.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        onTap(PushTap.fromPayload(launch!.notificationResponse?.payload));
      }
      return true;
    } catch (_) {
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
      _messaging = null;
      return false;
    }
  }

  void _showForeground(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;
    unawaited(
      _local
          .show(
            id: (message.messageId ?? '${message.sentTime}').hashCode,
            title: notification.title,
            body: notification.body,
            notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                _channel.id,
                _channel.name,
                channelDescription: _channel.description,
                importance: Importance.high,
                priority: Priority.high,
              ),
            ),
            payload: jsonEncode(message.data),
          )
          .catchError((Object _) {}),
    );
  }

  @override
  Future<bool> requestPermission() async {
    final messaging = _messaging;
    if (messaging == null) return false;
    final settings = await messaging.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  // API token registrasi FCM sengaja dipakai walau ditandai deprecated di
  // firebase_messaging 17: jalur penggantinya (register/onRegistered dengan
  // Firebase Installation ID) baru dirilis Oktober 2026 dan belum teruji di
  // perangkat proyek ini. Server (firebase-admin) masih mendukung `tokens`.
  // Migrasi ke FID dilakukan bersamaan di klien dan server.

  @override
  // ignore: deprecated_member_use
  Future<String?> getToken() async => _messaging?.getToken();

  @override
  Stream<String> get onTokenRefresh =>
      // ignore: deprecated_member_use
      _messaging?.onTokenRefresh ?? const Stream.empty();

  @override
  // ignore: deprecated_member_use
  Future<void> deleteToken() async => _messaging?.deleteToken();
}
