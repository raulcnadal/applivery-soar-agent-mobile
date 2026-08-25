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
what each actually does. `lib/main.dart` opens `ComplianceScreen` (`lib/status/compliance_screen.dart`), the
real compliance status UI — device/policy/risk summary up top, both of these folded into a collapsed
"Diagnostics" section, all with a pull-to-refresh.

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
  needed, just background/foreground the app or pull-to-refresh `ComplianceScreen`.
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
    <key>device_serial</key><string>TESTSERIAL123</string>
    <key>interval_sec</key><integer>3600</integer>
    <key>report_integrity</key><true/>
  </dict>
  </plist>
  EOF
  xcrun simctl spawn booted defaults import com.applivery.soar.mobile /tmp/managed_config.plist
  ```

  Run this *after* the app has launched at least once (so its UserDefaults suite exists), then
  background/foreground it or pull-to-refresh `ComplianceScreen`. Exact `simctl`/`defaults` behavior can vary
  a little by Xcode version — if `import` doesn't pick up, `defaults write` the same keys individually as a
  fallback.

**Root/jailbreak detection** can only be meaningfully verified on a real device — see the "Simulator
can't be jailbroken" note in `JailbreakDetector.swift`'s own doc comment and `ARCHITECTURE.md` §2.3. The
Diagnostics section's integrity panel will just report `simulator_checks_skipped` there, which is the
*correct* result, not a bug.

**mTLS identity — confirmed working end-to-end on both platforms** (real device serials from the live
Applivery fleet, real backend registration, real issued certs). Two things worth knowing if you're
re-verifying after a change:

1. `ios/Runner.xcodeproj`'s three plugin files were wired into `project.pbxproj` by hand, not through Xcode
   — if you add another native Swift file in future, don't assume it compiles just because it's on disk;
   confirm it under the Runner target's **Build Phases → Compile Sources**.
2. Android needs `android/app/build.gradle.kts`'s `packaging { resources { pickFirsts += ... } }` block —
   without it, `bcpkix-jdk18on`'s transitive jars collide with `jspecify` on an identical
   `META-INF/versions/9/OSGI-INF/MANIFEST.MF` path and `assembleDebug` fails outright.

Enrollment itself is silent — no button press needed. `ComplianceScreen` auto-enrolls the moment Managed
Configuration is complete (workspace, base URL, bootstrap token, device serial all present) and no
certificate exists yet, both on first load and on every live Managed Config push. A **Retry** button stays
visible in the identity row if the automatic attempt fails (bad network, backend briefly down, etc.) — it's
not the normal path on a managed device.

**mTLS-authenticated status calls — also confirmed end-to-end.** Once enrolled, the app now makes a real,
client-certificate-authenticated `GET /api/device-data/agent-status` call (native `mtlsRequest` — iOS
`URLSession` delegate presenting the Keychain `SecIdentity`, Android `KeyManagerFactory` scoped to the
`AndroidKeyStore` alias — see `ARCHITECTURE.md` §2.6) and renders the response on `ComplianceScreen`. If a
workspace hasn't enabled mTLS enforcement yet, every call here fails with 401/403 regardless of how correct
the on-device certificate is — see §2.6's "operational caveat" for why, and check that setting first before
assuming something's broken on the device side.

**Branding — icon, wordmark, theme.** The app icon, header wordmark, and Outfit typography now match the
BlueSky design system and the Windows/macOS agents' own look — see `ARCHITECTURE.md` §2.5 for the full asset
pipeline. Nothing here needs `flutter analyze`/`flutter test` to catch (fonts/images render fine or fail
silently in a way analyze can't see) — visually confirm on a real run:

1. App icon shows the blue shield glyph on the home screen / launcher (not the default Flutter icon).
2. The status screen's app bar shows the "Applivery | SOAR" wordmark image, not plain text — dark text on
   light background in light mode, light text on dark background in dark mode. Toggle the OS theme
   (Settings → Display on Android; Settings → Display & Brightness on iOS, or Simulator's Features menu) to
   check both.
3. Text throughout the screen renders in Outfit, not the platform system font (Outfit's lowercase "a" and
   "y" have a distinctive geometric look — compare against the default San Francisco/Roboto if unsure).

## Status

The real compliance status screen is live: `ComplianceScreen` shows this device's match/compliance state,
risk tier/score, and applicable-policy list, sourced from a genuine mTLS-authenticated
`GET /api/device-data/agent-status` call (native client-certificate TLS on both platforms — see
`ARCHITECTURE.md` §2.6) — not placeholder data. Managed Config and jailbreak/root detection are folded into
a collapsed Diagnostics section rather than being the primary UI. mTLS device identity covers registration,
silent auto-enrollment, and now authenticated requests bound to the stored hardware-backed key
(`caCertPem`/full chain now captured too); renewal (`POST /api/device-mtls/renew`) doesn't have a Dart-side
caller yet but the native primitive it needs is the same one already built. App icon, header wordmark, and
Outfit typography match the BlueSky design system and the Windows/macOS agents' own look (§2.5). Still not
started: the actual report loop (`POST /api/device-data/report`/`report-apps`) and broader endpoint
protection (Phase 2). See `ARCHITECTURE.md` for the phased scope and the open distribution/backend questions
still to resolve — in particular, a workspace needs `mtlsEnforcementEnabled` on before any of this actually
works end-to-end (§2.6).
