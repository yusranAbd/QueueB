import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:queueb_client/src/api.dart';
import 'package:queueb_client/src/config.dart';
import 'package:queueb_client/src/push/push_messaging.dart';
import 'package:queueb_client/src/push/push_registrar.dart';
import 'package:timezone/data/latest.dart' as tz;

class FakePushMessaging implements PushMessaging {
  FakePushMessaging({this.available = true, this.permission = true});

  final bool available, permission;
  String? token = 'fcm-token-1';
  final refresh = StreamController<String>.broadcast();
  PushTapHandler? onTap;
  int permissionRequests = 0, deletes = 0;

  @override
  Future<bool> initialize({required PushTapHandler onTap}) async {
    this.onTap = onTap;
    return available;
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get onTokenRefresh => refresh.stream;

  @override
  Future<void> deleteToken() async => deletes++;
}

class FakeBackend {
  FakeBackend(this.peran);

  final String peran;
  final requests = <({String method, String path, Object? body})>[];

  Iterable<({String method, String path, Object? body})> get push =>
      requests.where((r) => r.path.endsWith('/perangkat-push'));

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    requests.add((
      method: request.method,
      path: path,
      body: request.body.isEmpty ? null : jsonDecode(request.body),
    ));
    final user = {
      'id': 'akun-$peran',
      'nama': 'Akun $peran',
      'email': '$peran@test.local',
      'peran': peran,
    };
    Object? data = <String, dynamic>{};
    if (path.endsWith('/auth/login')) {
      data = {'accessToken': 'access', 'refreshToken': 'refresh', 'user': user};
    } else if (path.endsWith('/auth/me')) {
      data = user;
    } else if (path.endsWith('/perangkat-push')) {
      data = request.method == 'PUT' ? {'terdaftar': true} : {'dihapus': true};
    }
    return http.Response(
      jsonEncode(data),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

QueueApi apiFor(FakeBackend backend) => QueueApi(
  config: AppConfig(apiBaseUrl: 'http://localhost/api/v1', realtime: false),
  client: MockClient(backend.handle),
);

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  setUpAll(tz.initializeTimeZones);

  test('pasien yang login mendaftarkan token Android sekali', () async {
    final backend = FakeBackend('USER');
    final api = apiFor(backend);
    final messaging = FakePushMessaging();
    final registrar = PushRegistrar(api: api, messaging: messaging);
    await registrar.start();

    await api.login('USER@test.local', 'rahasia123');
    await settle();
    api.notifyListeners();
    await settle();

    expect(messaging.permissionRequests, 1);
    expect(backend.push, hasLength(1));
    expect(backend.push.single.method, 'PUT');
    expect(backend.push.single.body, {
      'token': 'fcm-token-1',
      'platform': 'ANDROID',
    });
    registrar.dispose();
  });

  test('token tetap didaftarkan walau izin notifikasi ditolak', () async {
    final backend = FakeBackend('USER');
    final api = apiFor(backend);
    final registrar = PushRegistrar(
      api: api,
      messaging: FakePushMessaging(permission: false),
    );
    await registrar.start();
    await api.login('USER@test.local', 'rahasia123');
    await settle();

    expect(backend.push.single.method, 'PUT');
    registrar.dispose();
  });

  test('token baru dari FCM dikirim ulang untuk pasien yang sama', () async {
    final backend = FakeBackend('USER');
    final api = apiFor(backend);
    final messaging = FakePushMessaging();
    final registrar = PushRegistrar(api: api, messaging: messaging);
    await registrar.start();
    await api.login('USER@test.local', 'rahasia123');
    await settle();

    messaging.refresh.add('fcm-token-2');
    await settle();

    expect(backend.push.map((r) => (r.body as Map)['token']), [
      'fcm-token-1',
      'fcm-token-2',
    ]);
    registrar.dispose();
  });

  test('logout menghapus token di server sebelum sesi dicabut', () async {
    final backend = FakeBackend('USER');
    final api = apiFor(backend);
    final messaging = FakePushMessaging();
    final registrar = PushRegistrar(api: api, messaging: messaging);
    await registrar.start();
    await api.login('USER@test.local', 'rahasia123');
    await settle();

    await api.logout();
    await settle();

    final paths = backend.requests
        .map((r) => '${r.method} ${r.path.split('/api/v1').last}')
        .toList();
    expect(
      paths.indexOf('DELETE /perangkat-push'),
      lessThan(paths.indexOf('POST /auth/logout')),
    );
    expect(backend.push.last.body, {'token': 'fcm-token-1'});
    expect(messaging.deletes, 1);
    expect(api.user, isNull);
    registrar.dispose();
  });

  for (final peran in ['ADMIN', 'PETUGAS', 'DOKTER']) {
    test('peran $peran tidak mendaftarkan push', () async {
      final backend = FakeBackend(peran);
      final api = apiFor(backend);
      final messaging = FakePushMessaging();
      final registrar = PushRegistrar(api: api, messaging: messaging);
      await registrar.start();
      await api.login('$peran@test.local', 'rahasia123');
      await settle();
      await api.logout();
      await settle();

      expect(backend.push, isEmpty);
      expect(messaging.permissionRequests, 0);
      registrar.dispose();
    });
  }

  test('tanpa Firebase (Web/QA lokal) tidak ada request push', () async {
    final backend = FakeBackend('USER');
    final api = apiFor(backend);
    final registrar = PushRegistrar(
      api: api,
      messaging: const DisabledPushMessaging(),
    );
    await registrar.start();
    await api.login('USER@test.local', 'rahasia123');
    await api.logout();
    await settle();

    expect(registrar.available, isFalse);
    expect(backend.push, isEmpty);
    expect(api.beforeLogout, isNull);
  });

  test('tap notifikasi diteruskan ke portal pasien', () async {
    final api = apiFor(FakeBackend('USER'));
    final messaging = FakePushMessaging();
    final registrar = PushRegistrar(api: api, messaging: messaging);
    await registrar.start();

    messaging.onTap!(
      PushTap.fromPayload('{"notifikasiId":"n1","tiketAntreanId":"t1"}'),
    );

    expect(api.pushTap.value?.notifikasiId, 'n1');
    expect(api.pushTap.value?.tiketAntreanId, 't1');
    expect(PushTap.fromPayload('bukan json').notifikasiId, isNull);
    registrar.dispose();
  });
}
