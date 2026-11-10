import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:queueb_client/src/api.dart';
import 'package:queueb_client/src/staff_manual_check_in.dart';

Map<String, dynamic> ticket({
  bool allowed = true,
  String status = 'DIPESAN',
  String? reason,
}) => {
  'tiketId': 'ticket-1',
  'nomorAntrean': 'A-025',
  'status': status,
  'namaPasien': 'Budi S.',
  'jenisAntrean': 'ANTREAN_HARIAN',
  'layanan': {'id': 'svc', 'nama': 'Poli Umum'},
  'dapatCheckInManual': allowed,
  'alasan': reason,
};

void main() {
  Future<void> open(
    WidgetTester tester, {
    required Future<Map<String, dynamic>> Function(String) lookup,
    required Future<Map<String, dynamic>> Function(String) checkIn,
    VoidCallback? onCheckedIn,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StaffManualCheckIn(
            lookup: lookup,
            checkIn: checkIn,
            onCheckedIn: onCheckedIn,
          ),
        ),
      ),
    );
  }

  testWidgets('format nomor salah tidak mengirim request', (tester) async {
    var calls = 0;
    await open(
      tester,
      lookup: (_) async {
        calls++;
        return ticket();
      },
      checkIn: (_) async => {},
    );
    await tester.enterText(
      find.byKey(const ValueKey('staff-manual-number')),
      '025',
    );
    await tester.tap(find.byKey(const ValueKey('staff-manual-search')));
    await tester.pumpAndSettle();
    expect(find.textContaining('format seperti A-025'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets(
    'cari lalu check-in manual memanggil API dan menyegarkan daftar',
    (tester) async {
      final lookups = <String>[], checkIns = <String>[];
      var refreshed = 0;
      await open(
        tester,
        lookup: (number) async {
          lookups.add(number);
          return ticket();
        },
        checkIn: (id) async {
          checkIns.add(id);
          return {
            'tiketId': id,
            'nomorAntrean': 'A-025',
            'status': 'MENUNGGU',
            'namaPasien': 'Budi Santoso',
            'namaPoliklinik': 'Poli Umum',
          };
        },
        onCheckedIn: () => refreshed++,
      );
      await tester.enterText(
        find.byKey(const ValueKey('staff-manual-number')),
        'a-025',
      );
      await tester.tap(find.byKey(const ValueKey('staff-manual-search')));
      await tester.pumpAndSettle();
      expect(lookups, ['A-025']);
      expect(find.textContaining('Pasien: Budi S.'), findsOneWidget);
      expect(find.textContaining('Cocokkan nama'), findsOneWidget);
      expect(checkIns, isEmpty);

      await tester.tap(find.byKey(const ValueKey('staff-manual-confirm')));
      await tester.pumpAndSettle();
      expect(checkIns, ['ticket-1']);
      expect(refreshed, 1);
      expect(find.byKey(const ValueKey('staff-qr-result')), findsOneWidget);
      expect(find.byKey(const ValueKey('staff-manual-ticket')), findsNothing);
    },
  );

  testWidgets(
    'tiket yang tidak boleh check-in menampilkan alasan tanpa tombol check-in',
    (tester) async {
      await open(
        tester,
        lookup: (_) async => ticket(
          allowed: false,
          status: 'MENUNGGU',
          reason: 'Pasien sudah check-in',
        ),
        checkIn: (_) async => fail('check-in tidak boleh dipanggil'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('staff-manual-number')),
        'A-025',
      );
      await tester.tap(find.byKey(const ValueKey('staff-manual-search')));
      await tester.pumpAndSettle();
      expect(find.text('Pasien sudah check-in'), findsOneWidget);
      expect(find.byKey(const ValueKey('staff-manual-confirm')), findsNothing);
    },
  );

  testWidgets('pesan error server ditampilkan dan tidak ada tiket tersisa', (
    tester,
  ) async {
    await open(
      tester,
      lookup: (_) async => throw const ApiException(
        404,
        'Tiket dengan nomor antrean ini tidak ditemukan hari ini',
      ),
      checkIn: (_) async => {},
    );
    await tester.enterText(
      find.byKey(const ValueKey('staff-manual-number')),
      'A-999',
    );
    await tester.tap(find.byKey(const ValueKey('staff-manual-search')));
    await tester.pumpAndSettle();
    expect(find.textContaining('tidak ditemukan hari ini'), findsOneWidget);
    expect(find.byKey(const ValueKey('staff-manual-ticket')), findsNothing);
  });
}
