// Smoke test for the placeholder app shell. Replace/expand once real screens
// (compliance status, Custom Device Checks, mTLS enrollment) land — see
// ARCHITECTURE.md for the planned lib/ structure.

import 'package:flutter_test/flutter_test.dart';

import 'package:soar_mobile/main.dart';
import 'package:soar_mobile/splash/splash_screen.dart';

void main() {
  testWidgets('App shell renders without crashing',
      (WidgetTester tester) async {
    await tester.pumpWidget(const SoarMobileApp());

    // main.dart's `home` is now SplashScreen, not ComplianceScreen directly
    // (see lib/splash/splash_screen.dart) — it shows first, on its own, for
    // a ~1.4s hold before handing off.
    expect(find.byType(SplashScreen), findsOneWidget);

    // Advance the virtual clock (flutter_test intercepts Timer/Future.delayed
    // and ties them to tester.pump's duration, not real wall-clock time)
    // past SplashScreen's 1400ms hold, which is when it calls
    // Navigator.pushReplacement, then past that route's own 400ms fade
    // transition, so ComplianceScreen is actually mounted by the time the
    // assertion below runs.
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // The AppBar title is now the AppBanner wordmark image (see
    // status/compliance_screen.dart), not a literal Text widget — check the
    // Semantics label wrapping it instead, which still carries "Applivery
    // SOAR Agent" for accessibility/screen readers.
    expect(find.bySemanticsLabel('Applivery SOAR Agent'), findsOneWidget);
  });
}
