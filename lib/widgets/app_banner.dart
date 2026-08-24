import 'package:flutter/material.dart';

/// Header wordmark — the same "banner logo top-left, replacing a centered
/// text title" placement the Windows tray card and macOS menu-bar card both
/// use (tray/card.go's buildCardContent header comment; macOS's
/// StatusCardView.banner()). Two theme-matched PNGs are bundled rather than
/// one (see ARCHITECTURE.md's branding section for the asset pipeline) —
/// the source SVG (assets/images/applivery-bp-login.svg) is a near-white
/// wordmark meant for a dark background, which is exactly the legibility
/// bug the Windows card had to fix for its own light mode (banner_light.bmp
/// vs banner_dark.bmp in tray/icons/) before this app existed. Unlike those
/// two platforms, Flutter doesn't need a hand-computed pixel aspect ratio
/// here — SizedBox+BoxFit.contain derives it from the asset automatically.
class AppBanner extends StatelessWidget {
  const AppBanner({super.key, this.height = 22});

  final double height;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asset = isDark
        ? 'assets/images/applivery_wordmark_on_dark.png'
        : 'assets/images/applivery_wordmark_on_light.png';
    return SizedBox(
      height: height,
      child: Image.asset(asset, fit: BoxFit.contain, alignment: Alignment.centerLeft),
    );
  }
}
