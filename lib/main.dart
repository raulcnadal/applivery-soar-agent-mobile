import 'package:flutter/material.dart';

// Entry point for the Applivery SOAR Agent mobile companion app.
//
// This is a placeholder shell — see ARCHITECTURE.md for the planned lib/
// structure (config/, status/, identity/, checks/, api/). Nothing here talks
// to the SOAR backend or any platform channel yet.
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
      home: const _PlaceholderHome(),
    );
  }
}

class _PlaceholderHome extends StatelessWidget {
  const _PlaceholderHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Applivery SOAR Agent')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Scaffold only — compliance status screen, Custom Device Checks, '
            'and mTLS enrollment land in later commits.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
