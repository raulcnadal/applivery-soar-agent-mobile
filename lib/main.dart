import 'package:flutter/material.dart';

import 'status/debug_screen.dart';
import 'theme/design_tokens.dart';

// Entry point for the Applivery SOAR Agent mobile companion app.
//
// See ARCHITECTURE.md for the planned lib/ structure. lib/config/ and
// lib/checks/ now have real platform-channel implementations
// (Managed Config + jailbreak/root detection); DebugScreen is a temporary
// visibility screen for verifying those work locally, not the real
// compliance status UI planned in ARCHITECTURE.md §0.2.
void main() {
  runApp(const SoarMobileApp());
}

class SoarMobileApp extends StatelessWidget {
  const SoarMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Applivery SOAR Agent',
      // BlueSky-derived tokens (lib/theme/design_tokens.dart) — see that
      // file's doc comments for how each Tailwind/BlueSky rule maps onto
      // Flutter. themeMode defaults to ThemeMode.system, so light/dark
      // switching (and with it, which wordmark variant AppBanner shows)
      // follows the OS setting with no extra wiring.
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: const DebugScreen(),
    );
  }
}
