import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../status/compliance_screen.dart';

/// First screen shown on cold start — a solid brand-blue background with the
/// dedicated splash lockup (assets/images/applivery-splash.svg — icon +
/// "SOAR Agent for mobile" wordmark, NOT the same asset as AppBanner's
/// compact header wordmark, applivery-bp-login.svg) fading and scaling in,
/// then a hold before handing off to [ComplianceScreen]. This is a
/// Flutter-drawn splash, not a native launch-screen replacement — iOS/
/// Android both still show their own static native launch image for the
/// sub-second gap between process start and Flutter's first frame
/// (unavoidable without native storyboard/XML changes, out of scope here);
/// this widget is what's visible for the deliberate, animated hold
/// immediately after that.
///
/// #0242E3 is the exact hex specified for this screen — very close to, but
/// not quite, design_tokens.dart's AppColors.brand600 (#0241E3), so it's
/// kept as its own local constant rather than reusing that token.
const Color _splashBackground = Color(0xFF0242E3);

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _controller.forward();
    _scheduleHandoff();
  }

  Future<void> _scheduleHandoff() async {
    // Total time on screen: ~900ms for the animation to settle, plus this
    // hold, plus the 400ms fade into ComplianceScreen below — long enough to
    // actually register as a splash screen rather than a flash, short enough
    // not to feel like a stall.
    await Future.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, __, ___) => const ComplianceScreen(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _splashBackground,
      body: Center(
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 64),
              // applivery-splash.svg's viewBox is 280x194 (icon stacked over
              // the wordmark, aspect ratio ~1.44) — a portrait lockup, not
              // the wide ~2.4 aspect of an earlier version, so it's sized
              // narrower than before to avoid stretching oddly on typical
              // phone widths.
              child: SvgPicture.asset(
                'assets/images/applivery-splash.svg',
                width: 220,
                semanticsLabel: 'Applivery SOAR Agent',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
