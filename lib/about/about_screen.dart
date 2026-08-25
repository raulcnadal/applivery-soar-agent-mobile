import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../widgets/app_banner.dart';

/// Short, static "what is this app" screen — linked from the very bottom of
/// the hidden diagnostics menu (long-press the header logo in
/// ComplianceScreen). Deliberately brief: this isn't documentation, just
/// enough for someone who long-presses a logo out of curiosity to understand
/// what they're looking at.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Center(child: AppBanner(height: 28)),
          const SizedBox(height: 32),
          Text(
            'Applivery SOAR Agent',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            'This app reports your device\'s security and compliance status '
            'to your organization\'s Applivery SOAR workspace, using a '
            'private certificate generated and stored only on this device. '
            'It never reads your files, messages, or personal data.',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Text(
            'Proudly crafted in Europe by Applivery 🇪🇺',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.gray500),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
