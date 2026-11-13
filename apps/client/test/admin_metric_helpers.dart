import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The operational dashboard shows four headline cards. Without a verified
/// report every card must read "—", never an invented zero.
void expectUnknownOperationalMetrics() {
  for (var i = 0; i < 4; i++) {
    final metric = find.byKey(ValueKey('admin-operational-metric-$i'));
    expect(metric, findsOneWidget);
    expect(
      find.descendant(
        of: metric,
        matching: find.textContaining(RegExp(r'^—'), findRichText: true),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: metric,
        matching: find.textContaining(RegExp(r'^0\b'), findRichText: true),
      ),
      findsNothing,
    );
  }
}
