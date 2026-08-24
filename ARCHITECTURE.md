# Architecture Guide

This is the developer-facing companion to [README.md](README.md). It explains how this repo is put
together, why it's structured the way it is, and — since this repo starts from an empty folder — what's
been decided so far versus what's still open.

## 0. What this repo is actually for

The Windows and macOS agent repos (`applivery-soar-agent-windows`, `applivery-soar-agent-macos`) exist for
one specific reason, stated plainly in the SOAR backend's own `ARCHITECTURE.md` §9: they collect signals
**"Applivery's own MDM API doesn't expose."** BitLocker/FileVault status, firewall state, Custom Device
Checks, hashed app inventory — none of that rides in on Applivery's native MDM sync for Windows/macOS, so a
background service fills the gap.

On iOS and Android, that premise is only partly true. Apple's MDM protocol and Android Enterprise's Device
Policy Controller already report a lot of base posture natively — OS version, passcode/encryption status,
installed apps — straight to Applivery, no agent required (`devices.md` already documents this: **"Re-attest
now... reports 'skipped' for platforms with no reporter, i.e. Android/iOS"**). So this app is not a port of
the desktop agents; it's a narrower, purpose-built companion that fills the *specific* gaps native MDM
telemetry leaves open, plus a couple of things the desktop agents don't do at all.

**Scope decided for this project (2026-08-24):**

1. **Gap-fill signals** — parity with the desktop agents' actual job: jailbreak/root detection (MDM
   protocols under-detect this), Custom Device Checks (same five-type contract as
   `customchecks_windows.go`/`customchecks_macos.go`, mobile-appropriate implementations), and mTLS agent
   identity for zero-trust API calls.
2. **In-app compliance status UI** — the mobile equivalent of the Windows tray card / macOS menu bar panel:
   a screen showing this device's compliance state, active violations, risk score, and self-service
   **Force Report** / **Force Evaluate Compliance** actions. Unlike desktop, there's no persistent
   background chrome (no tray, no menu bar) — this is a normal app screen, opened on demand, plus local
   notifications for compliance-transition alerts (parallel to `NotificationManager.swift` /
   the Windows tray's `Shell_NotifyIconW` balloons).
3. **Broader endpoint protection** — signals no desktop agent currently reports at all: on-device network/
   Wi-Fi threat detection (rogue AP, ARP spoofing, SSL-strip detection), phishing-link protection, and
   local malicious/repackaged-app scanning. This is a materially bigger lift than (1) and (2) — real-time
   traffic inspection and phishing heuristics are a product category of their own (commercial Mobile Threat
   Defense vendors like Zimperium, Lookout, Jamf Trust/Wandera exist specifically because this is hard to
   do well from scratch). **Open decision, not yet made:** build this in-house incrementally, or integrate
   an existing MTD SDK/API the way the desktop project already integrates external threat intel (MISP,
   VirusTotal, VulnCheck — see backend `ARCHITECTURE.md`) rather than reinventing detection logic. Treated
   as Phase 2, sequenced after (1) and (2) ship.

**Explicitly out of scope for now:** BYOD / self-enrollment (iOS User Enrollment, Android Work Profile).
This ships as a required, MDM-pushed app on corporate-owned, fully-managed devices only.

## 1. Why Flutter, and what it actually buys

Flutter gives one shared Dart layer for UI, local state, and networking/business logic across iOS and
Android — the same value proposition the two native agent repos get from sharing a design language and a
reporting *contract* despite having zero shared code. But almost everything that makes this an "agent"
rather than a normal app has no Dart API and has to be native code wired in via **platform channels**
(`MethodChannel`), same shape as a Flutter plugin:

- Jailbreak/root detection — native heuristics per platform, no meaningful cross-platform library exists
  that isn't itself just wrapping platform channels.
- Managed App Configuration reads — Apple's `com.apple.configuration.managed` key and Android's
  `RestrictionsManager` / App Restrictions Schema are OS-native MDM mechanisms with no Flutter-native API.
- Secure key storage for mTLS identity — iOS Keychain (`kSecClassKey`) and Android Keystore
  (hardware-backed where available), not something to hand-roll or trust to a generic plugin for a
  security-sensitive identity key.
- Background execution — iOS `BGTaskScheduler` (OS-throttled, no guaranteed interval, unlike the desktop
  agents' free-running `time.Ticker`) versus Android `WorkManager`. These have fundamentally different
  reliability guarantees and need to be designed around per-platform, not abstracted away.

So the practical shape is: one Dart app (UI, state, HTTP client, the compliance-status screen) sitting on
top of two still-separate native integration layers — conceptually the same split the Go daemon / Swift
menu bar app already have today, just recomposed as Dart-core-plus-two-native-plugins instead of two fully
separate binaries.

## 2. Repo layout

```
applivery-soar-agent-mobile/
  lib/
    main.dart                 # Entry point — currently home: DebugScreen (temporary, see status/)
    config/
      managed_config.dart     # ManagedConfig model + ManagedConfigChannel (method + event channel bridge)
    status/
      debug_screen.dart       # Dev-only visibility screen for config/ + checks/ — NOT the real status UI yet
    checks/
      integrity.dart          # IntegrityCheckResult model + IntegrityChannel (jailbreak/root check bridge)
    identity/                 # Not started — mTLS enrollment/renewal (Dart orchestration; native does the crypto)
    api/                      # Not started — HTTP client for the SOAR backend device-data endpoints
  ios/
    Runner/
      ManagedConfigPlugin.swift    # UserDefaults' com.apple.configuration.managed reader
      JailbreakDetector.swift      # JailbreakDetectorPlugin — heuristic checks
      AppDelegate.swift            # Registers both above via didInitializeImplicitFlutterEngine
  android/
    app/src/main/kotlin/com/applivery/soar/mobile/
      ManagedConfigPlugin.kt       # RestrictionsManager reader + ACTION_APPLICATION_RESTRICTIONS_CHANGED
      RootDetectorPlugin.kt        # Heuristic checks
      MainActivity.kt              # Registers both above via configureFlutterEngine
  .github/workflows/          # CI — build verification, same "no local toolchain" story as the other repos
  pubspec.yaml
  README.md
  ARCHITECTURE.md
```

`ios/` and `android/` were generated via `flutter create` on a real machine (see README.md's "Getting
started"), not hand-authored — this sandbox's network allowlist blocks the Flutter SDK installer's own
download. The two platform-channel Swift/Kotlin files under each are hand-authored source, same as `lib/`;
only the surrounding project scaffolding (Xcode project, Gradle files, generated icons) came from the
generator.

### 2.1 Platform channels — app-embedded, not real Flutter plugins

`ManagedConfigPlugin`/`RootDetectorPlugin` (Android) and `ManagedConfigPlugin`/`JailbreakDetectorPlugin`
(iOS) are registered by hand from `MainActivity.kt`/`AppDelegate.swift` — there's no `pubspec.yaml` entry,
no `.podspec`, no federated plugin package. A real plugin package is the right call when code needs to be
reused across apps or published; these are two small, app-specific bridges with no reuse case outside this
repo, so the extra packaging machinery would be pure overhead. Both platforms expose the **same channel
names and payload shape**, so `lib/config/` and `lib/checks/` need zero platform branching:

| Channel | Type | Method/event | Payload |
|---|---|---|---|
| `es.applivery.soar/managed_config` | Method | `getManagedConfig` | Flat map, see §2.2 |
| `es.applivery.soar/managed_config_stream` | Event | (stream) | Same flat map, re-sent on every native-side change |
| `es.applivery.soar/root_detector` | Method | `checkIntegrity` | `{isCompromised: bool, signals: [String]}` |

### 2.2 Managed Configuration schema

Delivered as a flat key-value payload — Android's App Restrictions (via Managed Google Play's restrictions
schema, configured against this app's `com.applivery.soar.mobile` id in the Play Console / pushed by
Applivery as the EMM) and iOS's Managed App Configuration (an MDM-pushed dictionary Apple lands under the
`com.apple.configuration.managed` key in this app's own `UserDefaults`). Same field names as the desktop
agents' `Config` struct (`config.go`/`registry_windows.go`) where a concept genuinely carries over, so
someone who already knows the Windows/macOS field table isn't learning a second vocabulary — deliberately
**not** a 1:1 field list, though: mobile is mTLS-only from day one (no `report_secret` legacy path to carry
forward) and has no BitLocker/FileVault/firewall equivalents to toggle.

| Key | Type | Required | Meaning |
|---|---|---|---|
| `workspace_slug` | string | yes | Applivery workspace this device reports into. |
| `base_url` | string | yes | SOAR backend base URL. No installer-baked default like the desktop agents have — a mobile build isn't produced per-tenant, so this is never optional. |
| `register_url` | string | no | Override for the mTLS enrollment endpoint only; falls back to `base_url`. Same semantics as the desktop agents' `RegisterURL` — see `managed_config.dart`'s doc comment. |
| `bootstrap_token` | string | yes (to enroll) | The Global Bootstrap Token, same value fleet-wide, consumed once on first successful mTLS registration. |
| `interval_sec` | int | no (default 3600) | Report cycle interval, once one exists. |
| `report_integrity` | bool | no (default true) | Whether to run the jailbreak/root check — an admin escape hatch, mirroring the desktop agents' per-signal `report_*` toggles. |

Not yet confirmed against Applivery UEM's actual console UI for defining this app's restrictions
schema/managed config keys — the table above is this repo's own design, still to be cross-checked against
whatever key-naming Applivery's console actually expects when this app's managed config is set up there for
real (ARCHITECTURE.md §3 flagged this as an open item; still open).

### 2.3 Jailbreak/root detection — what actually runs

Both native implementations return `{isCompromised: bool, signals: [String]}` rather than a bare boolean —
a signal list is useful both for the debug screen and, later, for feeding a
`selfReported.customCheckResults`-shaped payload to the backend (§3), same "show *why*, not just red/green"
shape the desktop agents' Custom Device Checks already use. **Explicitly best-effort, not tamper-proof** —
see each file's own doc comment for the full reasoning; briefly, this is the same caveat class as the
Windows/macOS agents' mutual-watchdog anti-tampering (a deterrent, not a guarantee against a determined,
hiding-aware attacker — Magisk's Zygisk/DenyList and jailbreak-hiding tweaks like Shadow/Flex exist
specifically to defeat exactly this class of check).

- **Android** (`RootDetectorPlugin.kt`): known `su` binary paths (Magisk, KernelSU, and older
  SuperSU-style layouts), known root-management app packages installed, `Build.TAGS` containing
  `test-keys`, and an actual write-probe against `/system` (creates then deletes a file — succeeding at all
  is itself the signal, independent of whether any of the other three also fire, since it also catches root
  methods that specifically hide the more commonly-checked-for artifacts above).
- **iOS** (`JailbreakDetector.swift`): known jailbreak-app/tweak-injection file paths (Cydia/Sileo/Zebra,
  MobileSubstrate, plus `/var/jb` for rootless jailbreaks like Dopamine), whether a jailbreak-tool URL scheme
  (`cydia://`, `sileo://`, ...) is openable (requires those schemes to be declared under
  `LSApplicationQueriesSchemes` in `Info.plist` — already done — or `canOpenURL` always returns false
  regardless of whether the app is installed), and a sandbox-escape write probe against `/private`. Skips
  all of the above on Simulator (`#if targetEnvironment(simulator)`) and reports a `simulator_checks_skipped`
  signal instead — the Simulator can't be jailbroken and the sandbox-escape probe in particular behaves
  differently there than on a real device, so running the real checks there would risk a false positive with
  no way to produce a true one to compare against.

## 3. Backend touch points (SOAR repo work, not this repo)

The desktop agents report through two endpoints in `modules/devices/deviceData.controller.ts`:
`POST /api/device-data/report` (fixed attributes + `customCheckResults`) and
`POST /api/device-data/report-apps`. Before mobile gap-fill signals can land anywhere, the backend side
needs:

- Confirm the device-matching key for mobile reports. The desktop `report` endpoint matches by serial
  number; mobile devices synced from Applivery may key more reliably on Applivery's own device id or UDID
  — needs verification against `deviceData.controller.ts` before assuming serial-number matching carries
  over unchanged.
- `GET /api/device-data/custom-checks?platform=ios|android` — extend the existing `platform` query param
  (currently `windows|macos`) rather than build a parallel mechanism.
- `GET /api/device-data/agent-status` is already platform-agnostic (it's a compliance/risk summary keyed by
  device id) — the compliance status screen can likely consume it unmodified, same contract
  `status_windows.go`/`status_macos.go` already use.
- mTLS: reuse `POST /api/device-mtls/register`'s CSR-based flow (same Global Bootstrap Token model) —
  the enrollment protocol doesn't care what platform generated the CSR, only the private-key storage
  mechanism differs (file-based on desktop vs. Keychain/Keystore here).
- New: a schema for what Applivery UEM's Managed App Configuration will actually deliver to this app, and a
  mapping table analogous to the Windows registry policy / macOS preferences plist field references in each
  desktop agent's README — this needs to be designed once Applivery's managed-config payload shape for this
  specific `com.applivery.soar.mobile` app is confirmed in the Applivery UEM console.

None of this is implemented yet — flagging it here so backend work isn't discovered piecemeal later.

## 4. Distribution — materially different from the desktop agents' zero-config download

The Windows/macOS agents publish through the SOAR backend's own `AgentBuild` mirror
(`POST /api/internal/agent-builds/:platform`, then `GET /api/agent-downloads/:platform` — an
unauthenticated direct-pull URL, `backend ARCHITECTURE.md` §9.2). That pattern doesn't carry over to mobile:

- **Android — Managed Google Play.** Confirmed: a paid Google Play Console developer account exists.
  Development-phase distribution is via **Managed Google Play private track** — apps distributed this way
  are uploaded through the Play Console (or the Play Developer API) and assigned to devices through the EMM
  (Applivery), not pulled from an arbitrary backend URL. CI's role here is to build a signed `.aab` and
  publish it to the private track (via `fastlane supply` or the Play Developer Publishing API), not to POST
  a binary into the SOAR backend the way the Windows agent's CI does.
- **iOS — manual Xcode distribution for now.** No formal Apple Developer Program / Apple Business Manager
  pipeline yet; builds are signed and installed manually via Xcode during development. **Flagging a
  terminology note:** iOS apps aren't "notarized" the way macOS apps are (notarization is a Gatekeeper
  concept, macOS-only) — the iOS equivalent of "properly signed for real distribution" is a valid
  provisioning profile plus, for fleet-wide MDM push without going through the public App Store, either
  **TestFlight** (small-scale, 90-day expiry, still needs an Apple Developer Program account) or **Apple
  Business Manager's Custom Apps (VPP)**, which is what actually lets an MDM silently push a non-App-Store
  binary at scale — that requires an Apple Developer Program *organization* account enrolled in Apple
  Business Manager. Worth deciding before Phase 1 needs to reach more than a handful of test devices.
- **Bundle/application id**: `com.applivery.soar.mobile` on both platforms (already decided).

## 5. CI (planned, not yet built)

Same philosophy as the other two repos — no local mobile build toolchain in this project's own tooling
(confirmed this session: this sandbox's network allowlist blocks Flutter SDK's own installer download, the
same category of restriction that blocks `prisma generate` in the backend repo). Real compile/build
verification has to happen on GitHub Actions runners with the actual SDKs, exactly like `windows-latest` and
`macos-latest` already do for the two existing agents. Planned shape once the Dart app and native scaffolds
exist:

- `subosito/flutter-action` to install Flutter on the runner, `flutter build ios --no-codesign` and
  `flutter build appbundle` for compile verification on every push/PR.
  On `macos-latest` for iOS (only place with a real Xcode toolchain, same reasoning `build-pkg.yml` already
  uses for the Swift menu bar app) and any runner for the Android side.
- Publish steps deferred until the distribution question in §4 is resolved — no point wiring an upload step
  against a pipeline that isn't decided yet.

## Further reading

[README.md](README.md) — getting-started steps, including the `flutter create` command to run locally to
generate the `ios/`/`android/` native project scaffolds this repo doesn't hand-author.
