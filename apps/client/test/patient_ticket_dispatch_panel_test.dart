import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:queueb_client/src/patient_ticket_dispatch_ui.dart';

Widget host(PatientTicketDispatchPanel panel) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: panel)),
);

void main() {
  testWidgets('menampilkan posisi dan jumlah di depan bila tersedia', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const PatientTicketDispatchPanel(
          position: 3,
          ahead: 2,
          checkInLabel: '12.59 WIB',
          checkInVerified: true,
        ),
      ),
    );
    expect(find.text('03'), findsOneWidget);
    expect(find.text('02'), findsOneWidget);
    expect(find.text('Posisi belum tersedia'), findsNothing);
    expect(
      find.textContaining('Janji temu dokter yang sudah dimulai'),
      findsNothing,
    );
  });

  testWidgets(
    'poli hibrida menambahkan catatan bahwa janji temu dapat mendahului',
    (tester) async {
      await tester.pumpWidget(
        host(
          const PatientTicketDispatchPanel(
            position: 4,
            ahead: 3,
            checkInLabel: '12.59 WIB',
            hybrid: true,
          ),
        ),
      );
      expect(
        find.textContaining('Janji temu dokter yang sudah dimulai'),
        findsOneWidget,
      );
    },
  );

  testWidgets('angka kosong disertai alasan yang dimengerti pasien', (
    tester,
  ) async {
    const reasons = {
      'MODE_ANTREAN_BELUM_DIDUKUNG':
          'Janji temu dipanggil sesuai jam dan ruang dokter',
      'LOKET_PELAYANAN_BELUM_TERSEDIA': 'Belum ada loket yang bertugas',
      'BELUM_MASUK_ANTREAN': 'Belum masuk antrean',
      null: 'Posisi belum tersedia',
    };
    for (final entry in reasons.entries) {
      await tester.pumpWidget(
        host(
          PatientTicketDispatchPanel(
            checkInLabel: '—',
            reason: entry.key,
            hybrid: true,
          ),
        ),
      );
      // Dua kartu (urutan dan di depan) menampilkan alasan yang sama.
      expect(find.text(entry.value), findsNWidgets(2), reason: '${entry.key}');
      expect(find.text('—'), findsWidgets);
      expect(
        find.textContaining('Janji temu dokter yang sudah dimulai'),
        findsNothing,
      );
    }
  });
}
