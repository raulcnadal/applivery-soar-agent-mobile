# Applivery SOAR Agent — Mobile (iOS & Android)

A Flutter companion app that fills the gaps Applivery's native MDM telemetry doesn't cover for iOS and
Android devices — see [ARCHITECTURE.md](ARCHITECTURE.md) for the full scope decision and why this isn't a
straight port of the [Windows](https://github.com/raulcnadal/applivery-soar-agent-windows) /
[macOS](https://github.com/raulcnadal/applivery-soar-agent-macos) agents.

**Package / bundle identifier:** `com.applivery.soar.mobile` (both platforms).

**Distribution:** required, MDM-pushed install on corporate-owned managed devices only (no BYOD/self-service
enrollment). Android via Managed Google Play (private track); iOS via manual Xcode installs during
development, with a real Apple Business Manager / TestFlight path to be decided before wider rollout — see
`ARCHITECTURE.md` §4.

## Getting started

This repo's `lib/` (the actual Dart application) is hand-authored and lives here in source control as
normal. The native `ios/` and `android/` platform wrapper projects are **not** committed as hand-written
boilerplate — they're the standard output of the Flutter CLI's project generator, and are best produced by
running it for real rather than reconstructed by hand.

If you're picking this repo up on a machine with Flutter installed (`flutter --version` to check; install
via https://docs.flutter.dev/get-started/install if not), generate the native scaffolds once with:

```sh
flutter create --platforms=ios,android --org com.applivery.soar --project-name mobile .
```

Run this from the repo root. It will *not* touch `lib/main.dart` if one already exists. Note the
`--org`/`--project-name` split: `flutter create` builds the bundle id as `<org>.<project-name>`, and
`--project-name` has to be a valid Dart package identifier (snake_case, no dots) — so it's split this way
specifically to land on the exact `com.applivery.soar.mobile` id, rather than the more obvious
`--org com.applivery --project-name soar_mobile`, which instead produces `com.applivery.soar_mobile`
(Android) / `com.applivery.soarMobile` (iOS). The first scaffold in this repo was generated with the wrong
split and hand-corrected afterward (`android/app/build.gradle.kts` namespace/applicationId, the
`MainActivity.kt` package + folder path, and every `PRODUCT_BUNDLE_IDENTIFIER` in
`ios/Runner.xcodeproj/project.pbxproj`) — using the command above from the start avoids needing to repeat
that by hand. After generating:

```sh
flutter pub get
flutter run          # or: flutter build ios --no-codesign / flutter build appbundle
```

## Status

Early scaffold — no working app yet. See `ARCHITECTURE.md` for the phased scope (gap-fill signals + status
UI first, endpoint protection second) and the open distribution/backend questions still to resolve.
