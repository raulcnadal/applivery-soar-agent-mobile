import 'package:flutter/material.dart';

/// Applivery BlueSky design tokens, translated from the web design system
/// (Tailwind CSS v4 `@theme` tokens: `brand-*`, `text-gray-*`, `rounded-*`,
/// `shadow-*`) into Flutter equivalents. Status/tier colors are kept
/// byte-identical to the Windows and macOS SOAR agents' own tokens (Windows:
/// `tray/card.go`'s color consts; macOS: `DesignTokens.swift`'s `AppColor`)
/// rather than invented fresh — those predate BlueSky and are this product's
/// own established compliance-tier convention, not something BlueSky
/// defines. A mixed Windows/macOS/mobile fleet should read as one product.
class AppColors {
  AppColors._();

  // Brand scale — BlueSky SKILL.md's Brand Color Tokens table, verbatim.
  static const brand50 = Color(0xFFEDF2FF);
  static const brand100 = Color(0xFFDCE7FF);
  static const brand200 = Color(0xFFBAD0FF);
  static const brand300 = Color(0xFF94B8FF);
  static const brand400 = Color(0xFF5C8BFF);
  static const brand500 = Color(0xFF1258FF); // focus rings
  static const brand600 = Color(0xFF0241E3); // primary — buttons, links
  static const brand700 = Color(0xFF0235C0); // hover on primary
  static const brand800 = Color(0xFF082D9E);
  static const brand900 = Color(0xFF0D2A7C);
  static const brand950 = Color(0xFF071847);

  // Status/tier colors — see class doc comment: matches AppColor.swift /
  // tray/card.go exactly, not a BlueSky token.
  static const success = Color(0xFF22C55E);
  static const danger = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);
  static const critical = Color(0xFFB91C1C);
  static const low = Color(0xFF64748B);
  static const gray400 = Color(0xFF9CA3AF);

  // Neutrals — standard Tailwind gray scale, used for BlueSky's text-color
  // rule (headings gray-900, body gray-600, muted gray-400/500) and for
  // card/border surfaces. Dark-mode values below are this app's own choice
  // (BlueSky's own dark-mode page, `references/pages.md`, wasn't part of
  // what's bundled here) — standard Tailwind gray-scale inversion.
  static const gray900 = Color(0xFF111827);
  static const gray700 = Color(0xFF374151);
  static const gray600 = Color(0xFF4B5563);
  static const gray500 = Color(0xFF6B7280);
  static const gray200 = Color(0xFFE5E7EB);
  static const gray100 = Color(0xFFF3F4F6);
  static const gray50 = Color(0xFFF9FAFB);

  // Dark-theme surfaces.
  static const surfaceDark = Color(0xFF111827); // gray-900
  static const cardDark = Color(0xFF1F2937); // gray-800
  static const borderDark = Color(0xFF374151); // gray-700
}

/// Maps a risk-tier string (as returned by the SOAR backend/compliance
/// evaluator) to the same 4-color ramp `AppColor.swift`'s and
/// `tray/card.go`'s own `tierColor` helpers use, with the same `gray400`
/// fallback for an unrecognized or absent tier.
Color tierColor(String? tier) {
  switch (tier?.toLowerCase()) {
    case 'critical':
      return AppColors.critical;
    case 'high':
      return AppColors.danger;
    case 'medium':
      return AppColors.warning;
    case 'low':
      return AppColors.low;
    default:
      return AppColors.gray400;
  }
}

/// BlueSky's spacing scale (`gap`/`p`/`m`/`w`/`h` Tailwind steps) as logical
/// pixels — `1`=4 · `2`=8 · `3`=12 · `4`=16 · `6`=24 · `8`=32 · `10`=40.
class AppSpacing {
  AppSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 40.0;
}

/// BlueSky's radius scale — `rounded-lg`=8 (inputs/buttons), `rounded-xl`=12
/// (cards), `rounded-2xl`=16 (modals/panels), `rounded-full` (badges).
class AppRadius {
  AppRadius._();
  static const md = 6.0;
  static const lg = 8.0;
  static const xl = 12.0;
  static const xxl = 16.0;
  static const full = 999.0;
}

/// BlueSky's type scale (`text-xs`..`text-4xl`) mapped onto Flutter's
/// TextTheme slots. `font-medium` is intentionally skipped per BlueSky's own
/// rule #10 in its SKILL.md ("font-medium is overridden to 400 — use
/// font-semibold for emphasis") — this app only ever uses w400/w600/w700,
/// matching the 3 Outfit weights actually bundled (see pubspec.yaml).
TextTheme buildAppTextTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final heading = isDark ? Colors.white : AppColors.gray900;
  final body = isDark ? AppColors.gray200 : AppColors.gray600;
  final muted = isDark ? AppColors.gray400 : AppColors.gray500;

  TextStyle style(double size, FontWeight weight, Color color) =>
      TextStyle(fontFamily: 'Outfit', fontSize: size, fontWeight: weight, color: color);

  return TextTheme(
    headlineMedium: style(24, FontWeight.w700, heading), // text-2xl — page headings
    titleLarge: style(20, FontWeight.w600, heading), // text-xl — section headings
    titleMedium: style(16, FontWeight.w600, heading), // text-base, emphasis
    bodyLarge: style(16, FontWeight.w400, body), // text-base
    bodyMedium: style(14, FontWeight.w400, body), // text-sm — default body/labels
    bodySmall: style(12, FontWeight.w400, muted), // text-xs — captions, timestamps
    labelLarge: style(14, FontWeight.w600, Colors.white), // button labels
  );
}

/// Builds the app's light or dark ThemeData from the tokens above. Called
/// once per brightness from `main.dart`'s MaterialApp (`theme`/`darkTheme`),
/// which is how a `--dart-define`-free run still gets correct light/dark
/// switching for free from the OS setting (`themeMode: ThemeMode.system`).
ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final colorScheme = ColorScheme.fromSeed(seedColor: AppColors.brand600, brightness: brightness);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    fontFamily: 'Outfit',
    scaffoldBackgroundColor: isDark ? AppColors.surfaceDark : AppColors.gray50,
    textTheme: buildAppTextTheme(brightness),
    // rounded-xl border border-gray-200 shadow-sm, per BlueSky rule #5 —
    // shadow is omitted (elevation: 0) since Material's default card shadow
    // reads heavier than BlueSky's subtle shadow-sm; the border alone gives
    // enough definition against this theme's off-white/near-black
    // scaffold background.
    cardTheme: CardThemeData(
      elevation: 0,
      color: isDark ? AppColors.cardDark : Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        side: BorderSide(color: isDark ? AppColors.borderDark : AppColors.gray200),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.brand600,
        foregroundColor: Colors.white,
        disabledBackgroundColor: isDark ? AppColors.borderDark : AppColors.gray200,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        textStyle: const TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: isDark ? AppColors.gray400 : AppColors.gray500),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: isDark ? AppColors.surfaceDark : AppColors.gray50,
      foregroundColor: isDark ? Colors.white : AppColors.gray900,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'Outfit',
        fontWeight: FontWeight.w600,
        fontSize: 20,
        color: isDark ? Colors.white : AppColors.gray900,
      ),
    ),
    dividerTheme: DividerThemeData(color: isDark ? AppColors.borderDark : AppColors.gray200),
    // focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-2
    focusColor: AppColors.brand500,
  );
}
