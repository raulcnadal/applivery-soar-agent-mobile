import 'package:flutter/material.dart';

import 'status/debug_screen.dart';

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
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0241E3),
        useMaterial3: true,
      ),
      home: const DebugScreen(),
    );
  }
}
