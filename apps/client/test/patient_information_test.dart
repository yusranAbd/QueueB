import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:queueb_client/src/config.dart';
import 'package:queueb_client/src/patient_information.dart';

const _umum = '00000000-0000-4000-8000-000000000001';
const _gigi = '00000000-0000-4000-8000-000000000002';

final _services = <Json>[
  {
    'id': _umum,
    'kode': 'PU01',
    'nama': 'Poli Umum',
    'kategori': 'POLIKLINIK',
    'modeReservasi': 'HIBRIDA',
    'deskripsi': 'Pemeriksaan keluhan kesehatan umum.',
    'aktif': true,
  },
  {
    'id': _gigi,
    'kode': 'PG01',
    'nama': 'Poli Gigi',
    'kategori': 'POLIKLINIK',
    'modeReservasi': 'JANJI_TEMU_DOKTER',
    'deskripsi': null,
    'aktif': true,
  },
];

Json _doctor(
  String id,
  String name,
  String serviceId, {
  bool linkActive = true,
}) => {
  'id': id,
  'nama': name,
  'spesialisasi': 'Dokter umum',
  'aktif': true,
  'dokterLayanan': [
    {'id': 'link-$id', 'layananId': serviceId, 'aktif': linkActive},
  ],
};

final _doctors = <Json>[
  _doctor('d2', 'dr. Rafi Mahendra', _umum),
  _doctor('d1', 'dr. Nabila Aryani', _umum),
  _doctor('d3', 'dr. Nonaktif', _gigi, linkActive: false),
];

Widget _page({double width = 390, double textScale = 1}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      size: Size(width, 800),
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(
      body: PatientInformation(
        services: _services,
        hours: const [],
        doctors: _doctors,
        date: '2026-11-10',
        hoursAvailable: false,
        loading: false,
        onRefresh: () {},
      ),
    ),
  ),
);

void main() {
  test('dokter dipetakan lewat relasi layanan aktif dan diurutkan', () {
    expect(PatientInformation.doctorsFor(_doctors, _umum).map(label), [
      'dr. Nabila Aryani',
      'dr. Rafi Mahendra',
    ]);
    expect(PatientInformation.doctorsFor(_doctors, _gigi), isEmpty);
  });

  testWidgets('menampilkan kontak darurat, deskripsi dan dokter per layanan', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_page());

    expect(find.text('Kontak darurat'), findsOneWidget);
    expect(find.text(ClinicContacts.ambulanceDisplay), findsOneWidget);
    expect(find.byKey(const ValueKey('ambulance-whatsapp')), findsOneWidget);
    // Tests run as a native build: no launcher, so the action copies.
    expect(find.text('Salin nomor'), findsOneWidget);
    expect(find.text('Chat WhatsApp'), findsNothing);
    expect(find.text('Nomor darurat nasional'), findsNothing);

    final umum = find.byKey(const ValueKey(('information', _umum)));
    await tester.dragUntilVisible(
      umum,
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(
      find.descendant(
        of: umum,
        matching: find.text('Pemeriksaan keluhan kesehatan umum.'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: umum, matching: find.text('dr. Nabila Aryani')),
      findsOneWidget,
    );

    final gigi = find.byKey(const ValueKey(('information', _gigi)));
    await tester.dragUntilVisible(
      gigi,
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(
      find.descendant(
        of: gigi,
        matching: find.text('Deskripsi layanan belum tersedia.'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: gigi,
        matching: find.text(
          'Belum ada dokter yang terdaftar pada layanan ini.',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('dr. Nonaktif'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final (width, scale) in [(320.0, 1.0), (360.0, 1.6), (412.0, 2.0)]) {
    testWidgets('tanpa overflow pada lebar $width dan teks x$scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_page(width: width, textScale: scale));
      await tester.dragUntilVisible(
        find.byKey(const ValueKey(('information', _gigi))),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
