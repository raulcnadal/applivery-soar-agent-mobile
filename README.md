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

## Testing locally

The app now has real platform-channel code: Managed Configuration reads (`lib/config/`) and a jailbreak/root
heuristic check (`lib/checks/`), both bridged to native Kotlin/Swift — see `ARCHITECTURE.md` §2.1–2.3 for
what each actually does. `lib/main.dart` currently opens `DebugScreen` (`lib/status/debug_screen.dart`), a
temporary visibility screen showing both live, with a pull-to-refresh.

**Basic checks** (run from the repo root):

```sh
flutter pub get
flutter analyze
flutter test
```

**Quick UI check without any MDM setup** — debug builds fall back to `--dart-define` values when the real
Managed Config channel comes back empty (the normal case on a fresh emulator/simulator), so you can see a
populated screen immediately:

```sh
flutter run \
  --dart-define=DEBUG_WORKSPACE_SLUG=test-workspace \
  --dart-define=DEBUG_BASE_URL=https://soar.example.com \
  --dart-define=DEBUG_BOOTSTRAP_TOKEN=test-token \
  --dart-define=DEBUG_DEVICE_SERIAL=TESTSERIAL123
```

This bypasses the native channel entirely — good for iterating on the Dart/UI side fast, but it doesn't
prove `ManagedConfigPlugin.kt`/`.swift` actually work. Root/jailbreak detection has no fallback (there's
nothing to fake meaningfully) — that panel exercises the real native code on every run.

**Real end-to-end test of the native Managed Config channel:**

- *Android* — plain `adb shell` has no command to set arbitrary app restrictions; that's DPC-only. Use
  Google's open-source [Test DPC](https://github.com/googlesamples/android-testdpc) app on an emulator: set
  it as device owner (`adb shell dpm set-device-owner com.afwsamples.testdpc/.DeviceAdminReceiver` — needs a
  freshly-wiped emulator with no accounts signed in), open Test DPC → **App Restrictions** → select this
  app → enter the key/value pairs from `ARCHITECTURE.md` §2.2 → save. This app's `ManagedConfigPlugin.kt`
  should pick the change up live via its `ACTION_APPLICATION_RESTRICTIONS_CHANGED` receiver — no restart
  needed, just background/foreground the app or pull-to-refresh `DebugScreen`.
- *iOS Simulator* — no real MDM enrollment is possible in Simulator, but you can seed the same
  `com.apple.configuration.managed` key `ManagedConfigPlugin.swift` reads:

  ```sh
  cat > /tmp/managed_config.plist <<'EOF'
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>workspace_slug</key><string>test-workspace</string>
    <key>base_url</key><string>https://soar.example.com</string>
    <key>bootstrap_token</key><string>test-token</string>
    <key>interval_sec</key><integer>3600</integer>
    <key>report_integrity</key><true/>
  </dict>
  </plist>
  EOF
  xcrun simctl spawn booted defaults import com.applivery.soar.mobile /tmp/managed_config.plist
  ```

  Run this *after* the app has launched at least once (so its UserDefaults suite exists), then
  background/foreground it or pull-to-refresh `DebugScreen`. Exact `simctl`/`defaults` behavior can vary a
  little by Xcode version — if `import` doesn't pick up, `defaults write` the same keys individually as a
  fallback.

**Root/jailbreak detection** can only be meaningfully verified on a real device — see the "Simulator
can't be jailbroken" note in `JailbreakDetector.swift`'s own doc comment and `ARCHITECTURE.md` §2.3.
`DebugScreen`'s integrity panel will just report `simulator_checks_skipped` there, which is the *correct*
result, not a bug.

**mTLS identity is the least-verified piece so far** — see `ARCHITECTURE.md` §2.4's three flagged items
before trusting it. In rough priority order once you're on a real Mac:

1. Open `ios/Runner.xcodeproj` in Xcode *first*, before running anything. The three new Swift plugin files
   (`ManagedConfigPlugin.swift`, `JailbreakDetector.swift`, `MtlsIdentityPlugin.swift`) were wired into
   `project.pbxproj` by hand, not through Xcode itself — confirm they appear under the Runner target's
   **Build Phases → Compile Sources** and that Xcode doesn't flag or silently rewrite anything on open.
2. With Managed Configuration seeded (either `--dart-define`s above, or a real/simulated push — see the
   Android Test DPC / iOS `simctl` steps above, this time including a real `device_serial` value), tap
   **Enroll now** on the mTLS identity panel. A failure surfaces inline with whatever error the backend or
   native side returned.
3. If a CSR is generated but registration still fails oddly, the CSR encoding itself is the first thing to
   suspect on iOS specifically (hand-rolled DER, never compiled or tested before this). Temporarily log
   `csrPem` from `MtlsIdentity.enroll()` (or write it to a file) and check it with
   `openssl req -in csr.pem -noout -text` — it should print a normal-looking CSR with an EC P-256 public key
   and a CN matching the device serial, not an OpenSSL parse error.

## Status

Early scaffold with two working platform-channel modules (Managed Config, jailbreak/root detection) behind a
temporary debug screen — no real compliance status UI, mTLS enrollment, or backend reporting yet. See
`ARCHITECTURE.md` for the phased scope (gap-fill signals + status UI first, endpoint protection second) and
the open distribution/backend questions still to resolve.
