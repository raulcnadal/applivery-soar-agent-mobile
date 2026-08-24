// Smoke test for the placeholder app shell. Replace/expand once real screens
// (compliance status, Custom Device Checks, mTLS enrollment) land — see
// ARCHITECTURE.md for the planned lib/ structure.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soar_mobile/main.dart';

void main() {
  testWidgets('App shell renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const SoarMobileApp());

    expect(find.text('Applivery SOAR Agent'), findsWidgets);
  });
}
