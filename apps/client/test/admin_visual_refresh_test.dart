import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:queueb_client/src/admin_dashboard.dart';
import 'package:queueb_client/src/admin_navigation.dart';
import 'package:queueb_client/src/admin_ui.dart';
import 'package:queueb_client/src/config.dart';
import 'package:timezone/data/latest.dart' as tz;

void main() {
  tz.initializeTimeZones();
  final config = AppConfig(
    apiBaseUrl: 'http://localhost/api/v1',
    serviceTimeZone: 'Asia/Jayapura',
  );
  final catalog = <String, List<Json>>{
    '/layanan': [
      {'id': 'c', 'nama': 'Poli Mata', 'aktif': false},
    ],
    '/dokter': [
      for (var i = 0; i < 3; i++)
        {
          'id': 'd$i',
          'aktif': i != 2,
          'dokterLayanan': [
            {'layananId': 'c', 'aktif': true},
          ],
        },
    ],
    '/loket': [
      {'id': 'r', 'aktif': true, 'layananId': 'c'},
    ],
    '/jadwal-praktik': [
      for (var i = 0; i < 7; i++)
        {
          'id': 's$i',
          'aktif': i < 4,
          'dokterLayanan': {'layananId': 'c'},
        },
    ],
  };
  for (final viewport in [
    const Size(375, 900),
    const Size(768, 1024),
    const Size(1366, 768),
    const Size(1440, 900),
    const Size(1920, 1080),
  ]) {
    testWidgets(
      'Admin welcome and compact table fit $viewport with real catalog values',
      (tester) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: AdminStyle.theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: AdminDashboard(
                    catalog: catalog,
                    config: config,
                    loading: false,
                    onSelect: (_) {},
                    administratorName: 'Administrator Pengujian',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Dashboard Operasional'), findsOneWidget);
        // Service time zone comes from config, shown as its local label.
        expect(find.textContaining('· WIT'), findsOneWidget);
        // The only clinic is inactive: no invented service cards or totals.
        expect(find.text('0 layanan aktif'), findsOneWidget);
        expect(find.text('Belum ada layanan aktif.'), findsOneWidget);
        expect(find.textContaining('admin-service-'), findsNothing);
        expect(find.text('128'), findsNothing);
        expect(find.textContaining('%'), findsNothing);
        expect(find.text('Notifikasi'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        // Without today's report the activity table is not faked.
        expect(find.byType(DataTable), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('Reload and service-card navigation stay functional', (
    tester,
  ) async {
    var reloaded = 0, selected = -1;
    final active = {
      ...catalog,
      '/layanan': [
        {'id': 'c', 'nama': 'Poli Mata', 'aktif': true},
      ],
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminStyle.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdminDashboard(
              catalog: active,
              config: config,
              loading: false,
              onSelect: (v) => selected = v,
              onRefresh: () => reloaded++,
              administratorName: '  ',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Poli Mata'), findsOneWidget);
    await tester.ensureVisible(find.text('Muat ulang'));
    await tester.tap(find.text('Muat ulang'));
    expect(reloaded, 1);
    await tester.ensureVisible(find.byTooltip('Kelola ruang/loket'));
    await tester.tap(find.byTooltip('Kelola ruang/loket'));
    expect(selected, 2);
  });
  testWidgets(
    'Dashboard sidebar groups modules while retaining direct navigation',
    (tester) async {
      var selected = -1;
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminStyle.theme,
          home: Scaffold(
            body: AdminNavigation(selected: -1, onSelect: (v) => selected = v),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The simplified sidebar keeps only the operational modules; slots and
      // reports are reached from their parent pages and the dashboard.
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('Dokter'), findsOneWidget);
      expect(find.text('Manajemen Display'), findsOneWidget);
      expect(find.text('Slot konsultasi'), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);
      await tester.tap(find.text('Dokter'));
      expect(selected, 1);
    },
  );
  testWidgets(
    'Compact table highlights a hovered row without making it selectable',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AdminStyle.theme,
          home: Scaffold(
            body: AdminTable(
              compact: true,
              rows: const [
                {'nama': 'Klinik QA'},
              ],
              columns: [AdminColumn('Poliklinik', (r) => r['nama'])],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Klinik QA')));
      await tester.pumpAndSettle();
      final source = tester
          .widget<PaginatedDataTable>(find.byType(PaginatedDataTable))
          .source;
      expect(source.getRow(0)!.color?.resolve({}), isNotNull);
      expect(source.getRow(0)!.onSelectChanged, isNull);
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(source.getRow(0)!.color, isNull);
    },
  );
  testWidgets('compact rows grow with accessible text scaling', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminStyle.theme,
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: AdminTable(
              rows: const [
                {'nama': 'Klinik QA'},
              ],
              columns: [AdminColumn('Poliklinik', (r) => r['nama'])],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PaginatedDataTable>(find.byType(PaginatedDataTable))
          .dataRowMaxHeight,
      greaterThan(48),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Identity renders only the supplied session name and safe initials',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: AdminIdentity(name: 'Siti Aminah')),
        ),
      );
      expect(find.text('Siti Aminah'), findsOneWidget);
      expect(find.text('SA'), findsOneWidget);
      expect(find.text('Administrator'), findsOneWidget);
      expect(find.text('Administrator Pengujian'), findsNothing);
    },
  );
}
