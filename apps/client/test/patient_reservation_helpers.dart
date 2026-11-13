import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reservation list ends with a "Buat Reservasi Baru" button (it replaced
/// the floating action button). Scroll to it and open the reservation choices.
Future<void> openCreateReservation(WidgetTester t) async {
  final button = find.byKey(const ValueKey('create-reservation'));
  await t.scrollUntilVisible(
    button,
    300,
    scrollable: find
        .descendant(
          of: find.byKey(const PageStorageKey('reservation-list')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await t.pumpAndSettle();
  await t.tap(button);
  await t.pumpAndSettle();
}
