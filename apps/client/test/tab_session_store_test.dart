import 'package:flutter_test/flutter_test.dart';
import 'package:queueb_client/src/session_store.dart';

class FakeTabStorage implements TabStorage {
  final values = <String, String>{};
  bool dropWrites = false;
  @override
  String? getItem(String key) => values[key];
  @override
  void setItem(String key, String value) {
    if (!dropWrites) values[key] = value;
  }

  @override
  void removeItem(String key) => values.remove(key);
}

void main() {
  const api = 'https://api.example.test/api/v1';
  const pair = SessionCredentials('access-1', 'refresh-1');

  test('pasangan token bertahan saat tab dimuat ulang', () async {
    final storage = FakeTabStorage();
    await TabSessionStore(apiBase: api, storage: storage).write(pair);
    // Instance baru meniru aplikasi yang dimuat ulang pada tab yang sama.
    final restored = await TabSessionStore(
      apiBase: api,
      storage: storage,
    ).read();
    expect(restored?.accessToken, 'access-1');
    expect(restored?.refreshToken, 'refresh-1');
  });

  test('logout menghapus kredensial dari tab', () async {
    final storage = FakeTabStorage();
    final store = TabSessionStore(apiBase: api, storage: storage);
    await store.write(pair);
    await store.clear();
    expect(storage.values, isEmpty);
    expect(await store.read(), isNull);
  });

  test('token API lain tidak dipakai', () async {
    final storage = FakeTabStorage();
    await TabSessionStore(apiBase: api, storage: storage).write(pair);
    final other = TabSessionStore(
      apiBase: 'https://lain.example.test/api/v1',
      storage: storage,
    );
    expect(await other.read(), isNull);
  });

  test(
    'isi rusak atau amplop asing dihapus dan tidak memulihkan sesi',
    () async {
      final storage = FakeTabStorage();
      final store = TabSessionStore(apiBase: api, storage: storage);
      for (final corrupt in [
        'bukan json',
        '[]',
        '{"version":1,"apiBase":"https://lain.example.test/api/v1","accessToken":"a","refreshToken":"r"}',
        '{"version":1,"apiBase":"$api","accessToken":"","refreshToken":"r"}',
      ]) {
        storage.values['queueb.session.v1.$api'] = corrupt;
        expect(await store.read(), isNull, reason: corrupt);
        expect(storage.values, isEmpty, reason: corrupt);
      }
    },
  );

  test('penulisan yang tidak tersimpan dilaporkan sebagai kegagalan', () async {
    final storage = FakeTabStorage()..dropWrites = true;
    await expectLater(
      TabSessionStore(apiBase: api, storage: storage).write(pair),
      throwsStateError,
    );
  });

  test('platform non-Web tidak memakai penyimpanan tab', () {
    expect(platformSessionStore(api), isNot(isA<TabSessionStore>()));
  });
}
