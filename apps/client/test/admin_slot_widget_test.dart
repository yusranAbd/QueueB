import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:queueb_client/src/admin.dart';
import 'package:queueb_client/src/admin_data.dart';
import 'package:queueb_client/src/admin_navigation.dart';
import 'package:queueb_client/src/admin_ui.dart';
import 'package:queueb_client/src/features/admin/application/slot_session_cubit.dart';
import 'package:queueb_client/src/features/admin/application/practice_schedule_cubit.dart';
import 'package:queueb_client/src/features/admin/data/admin_schedule_repository.dart';
import 'package:timezone/data/latest.dart' as tz;

import 'admin_action_helpers.dart';
import 'admin_slot_cubit_test.dart' show SlotFixture;

void main() {
  setUpAll(tz.initializeTimeZones);
  late SlotFixture f;
  setUp(() => f = SlotFixture());
  tearDown(() => f.dispose());
  Future<void> open(WidgetTester tester, {bool history = true}) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminStyle.theme,
        home: Scaffold(body: AdminPage(api: f.api, initialSection: 5)),
      ),
    );
    await tester.pumpAndSettle();
    expect(f.reads, isEmpty);
    expect(find.text('Dari tanggal'), findsNothing);
    expect(find.text('Sampai tanggal'), findsNothing);
    // Fixture sessions are dated in the past, so they live under history.
    if (history) {
      await tester.tap(find.text('Riwayat / nonaktif'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Poli').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dokter').last);
    await tester.pumpAndSettle();
  }

  // Index 0/1 means fixture session 'a'/'b'; history order is not asserted.
  Finder tile(int index) => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is AdminSlotSession && w.session['id'] == ['a', 'b'][index],
    ),
    matching: find.byType(ExpansionTile),
  );
  SlotSessionCubit scope(WidgetTester tester, int index) =>
      tester.element(tile(index)).read<SlotSessionCubit>();
  Future<void> expand(WidgetTester tester, [int index = 0]) async {
    await tester.tap(tile(index));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'per-session lazy load and scoped refresh leave parent data view intact',
    (tester) async {
      await open(tester);
      expect(find.byType(AdminSlotSession), findsNWidgets(2));
      await expand(tester);
      final c = scope(tester, 0);
      expect(f.reads, {'a': 1});
      final view = tester.state(find.byType(AdminDataView));
      final practice = tester
          .element(find.byType(AdminDataView))
          .read<PracticeScheduleCubit>();
      expect(c.repository.catalog, same(practice.repository));
      f.data['a']!.single['kapasitas'] = 7;
      await tester.tap(find.text('Muat ulang slot').first);
      await tester.pumpAndSettle();
      expect(c.state.slots.single['kapasitas'], 7);
      expect(tester.state(find.byType(AdminDataView)), same(view));
      await expand(tester, 1);
      expect(f.reads['b'], 1);
      expect(scope(tester, 1).state.slots.single['id'], 'slot-b');
      final reloadGate = Completer<void>();
      f.readGates[('a', 3)] = reloadGate;
      f.masters['/jadwal-layanan']!.single['kapasitasHarian'] = 27;
      await tester.tap(find.text('Muat ulang'));
      await tester.pump();
      expect(f.reads['a'], 3);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Muat ulang'),
            )
            .onPressed,
        isNull,
      );
      reloadGate.complete();
      await tester.pumpAndSettle();
      expect(f.reads['a'], 3);
      expect(f.reads['b'], 2);
      await tester.tap(find.text('Dashboard'));
      await tester.pumpAndSettle();
      expect(f.reads['a'], 3);
      f.data['a']!.single['kapasitas'] = 8;
      // Slots are no longer a sidebar entry; return through the section API.
      tester.widget<AdminNavigation>(find.byType(AdminNavigation)).onSelect!(5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Riwayat / nonaktif'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Poli').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dokter').last);
      await tester.pumpAndSettle();
      await expand(tester);
      expect(scope(tester, 0), same(c));
      expect(c.state.slots.single['kapasitas'], 8);
      expect(f.reads['a'], 4);
      await tester.pumpWidget(const SizedBox());
      expect(c.isClosed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'initial loading and failure never claim an empty verified session; retry loads empty',
    (tester) async {
      await open(tester);
      final gate = Completer<void>();
      f.readGates[('a', 1)] = gate;
      f.readError = 503;
      await tester.tap(tile(0));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      expect(find.text('Tidak ada slot yang sesuai filter.'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Layanan sedang mengalami gangguan'),
        findsOneWidget,
      );
      expect(find.text('Tidak ada slot yang sesuai filter.'), findsNothing);
      f.readError = null;
      f.data['a'] = [];
      await tester.tap(find.text('Muat ulang slot'));
      await tester.pumpAndSettle();
      expect(find.text('Tidak ada slot yang sesuai filter.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'standalone adapter swaps session with old response still pending',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget page(String id) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AdminSlotSession(
              key: const ValueKey('same-card'),
              api: f.api,
              session: SlotFixture.session(id),
              revision: 1,
              status: '',
              search: '',
              busy: false,
              onEdit: (_) {},
              onDeactivate: (_) {},
            ),
          ),
        ),
      );
      final gate = Completer<void>();
      f.readGates[('a', 1)] = gate;
      await tester.pumpWidget(page('a'));
      await tester.tap(find.byType(ExpansionTile));
      await tester.pump();
      await tester.pumpWidget(page('b'));
      await tester.pumpAndSettle();
      final c = tester
          .element(find.byType(ExpansionTile))
          .read<SlotSessionCubit>();
      expect(c.state.sessionId, 'b');
      expect(c.state.slots.single['id'], 'slot-b');
      gate.complete();
      await tester.pumpAndSettle();
      expect(c.state.slots.single['id'], 'slot-b');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final reject in [false, true]) {
    testWidgets(
      'slot edit ${reject ? 'keeps conflict and old server row' : 'uses Cubit, Jakarta payload and updated server row'}',
      (tester) async {
        await open(tester);
        await expand(tester);
        final c = scope(tester, 0);
        await adminAction(tester, 'Ubah');
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Kapasitas slot'),
          '3',
        );
        f.writeError = reject ? 409 : null;
        await tester.tap(find.text('Simpan'));
        await tester.pumpAndSettle();
        final write = f.calls.singleWhere((r) => r.method == 'PATCH');
        expect(jsonDecode(write.body)['mulaiPada'], '2026-10-28T17:00:00.000Z');
        expect(jsonDecode(write.body)['kapasitas'], 3);
        expect(c.state.slots.single['kapasitas'], reject ? 2 : 3);
        if (reject) {
          expect(
            find.textContaining('Slot terisi atau konflik jadwal'),
            findsWidgets,
          );
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.text('Data disimpan.'), findsNothing);
        } else {
          expect(find.byType(AlertDialog), findsNothing);
          expect(f.reads, {'a': 2});
        }
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final reject in [false, true]) {
    testWidgets(
      'slot permanent delete confirmation ${reject ? 'retains occupied slot' : 'removes verified slot'}',
      (tester) async {
        await open(tester);
        await expand(tester);
        final c = scope(tester, 0);
        await adminAction(tester, 'Hapus');
        expect(find.text('Hapus Data?'), findsOneWidget);
        expect(f.calls.where((r) => r.method == 'DELETE'), isEmpty);
        f.writeError = reject ? 409 : null;
        await tester.tap(find.text('Hapus Permanen'));
        await tester.pumpAndSettle();
        expect(
          f.calls.singleWhere((r) => r.method == 'DELETE').url.path,
          '/api/v1/slot-praktik/slot-a/permanen',
        );
        expect(c.state.slots, hasLength(reject ? 1 : 0));
        expect(
          find.text('Hapus Data?'),
          reject ? findsOneWidget : findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }

  /// New slots may only be added to sessions that have not ended, so this
  /// moves both fixture sessions to 00:00 WIB three days from today.
  (DateTime, DateTime) moveSessionsToFuture() {
    final day = DateTime.parse(f.api.config.today).add(const Duration(days: 3));
    final start = DateTime.utc(
      day.year,
      day.month,
      day.day,
    ).subtract(const Duration(hours: 7));
    for (final s in f.masters['/jadwal-praktik']!) {
      s['tanggal'] = day.toIso8601String().substring(0, 10);
      s['mulaiPada'] = start.toIso8601String();
      s['selesaiPada'] = start.add(const Duration(hours: 2)).toIso8601String();
    }
    for (final slot in f.data.values.expand((v) => v)) {
      slot['mulaiPada'] = start.toIso8601String();
      slot['selesaiPada'] = start
          .add(const Duration(minutes: 15))
          .toIso8601String();
    }
    return (day, start);
  }

  testWidgets(
    'existing create slot form routes selected session through its sole Cubit',
    (tester) async {
      final (day, start) = moveSessionsToFuture();
      await open(tester, history: false);
      await expand(tester);
      final c = scope(tester, 0);
      await tester.tap(find.text('Tambah'));
      await tester.pumpAndSettle();
      Future<void> pick(String field, String minute) async {
        await tester.tap(find.byTooltip('Pilih $field (YYYY-MM-DDTHH:mm)'));
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsOneWidget);
        await tester.tap(find.text('${day.day}').last);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsOneWidget);
        await tester.tap(find.byIcon(Icons.keyboard_outlined));
        await tester.pumpAndSettle();
        final fields = find.descendant(
          of: find.byType(TimePickerDialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(fields.at(0), '00');
        await tester.enterText(fields.at(1), minute);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }

      // The page-level form asks for the session explicitly. Both fixture
      // sessions share a label; choices sort by start then id, so first is 'a'.
      final choice = find.descendant(
        of: find.byType(AdminSearchChoice),
        matching: find.byType(TextField),
      );
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('· Dokter · Poli · Ruang').first);
      await tester.pumpAndSettle();
      await pick('Mulai', '15');
      await pick('Selesai', '30');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Kapasitas slot'),
        '2',
      );
      await tester.tap(find.text('Simpan'));
      await tester.pumpAndSettle();
      expect(f.calls.where((r) => r.method == 'POST'), hasLength(1));
      final body = jsonDecode(
        f.calls.singleWhere((r) => r.method == 'POST').body,
      );
      expect(body['jadwalPraktikId'], 'a');
      expect(
        body['mulaiPada'],
        start.add(const Duration(minutes: 15)).toIso8601String(),
      );
      expect(c.state.slots, hasLength(2));
      expect(f.reads['b'], isNull);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'capacity scheduling mutation invalidates relevant open slots and logout clears them',
    (tester) async {
      await open(tester);
      await expand(tester);
      final c = scope(tester, 0);
      final service = ServiceScheduleCubit(
        AdminScheduleRepository(c.repository.catalog),
      );
      f.data['a']!.single['tersedia'] = false;
      await tester.runAsync(() async {
        await service.save({'kapasitasHarian': 30}, id: 'hours');
        await c.settled;
      });
      await tester.pumpAndSettle();
      expect(f.reads, {'a': 2});
      expect(c.state.slots.single['tersedia'], isFalse);
      await tester.runAsync(f.api.clearSession);
      await tester.pumpAndSettle();
      expect(c.state.slots, isEmpty);
      expect(c.isClosed, isTrue);
      await service.close();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
