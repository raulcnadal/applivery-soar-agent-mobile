// Smoke test for the placeholder app shell. Replace/expand once real screens
// (compliance status, Custom Device Checks, mTLS enrollment) land — see
// ARCHITECTURE.md for the planned lib/ structure.

import 'package:flutter_test/flutter_test.dart';

import 'package:soar_mobile/main.dart';

void main() {
  testWidgets('App shell renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const SoarMobileApp());

    // The AppBar title is now the AppBanner wordmark image (see
    // debug_screen.dart), not a literal Text widget — check the Semantics
    // label wrapping it instead, which still carries "Applivery SOAR Agent"
    // for accessibility/screen readers.
    expect(find.bySemanticsLabel('Applivery SOAR Agent'), findsOneWidget);
  });
}
