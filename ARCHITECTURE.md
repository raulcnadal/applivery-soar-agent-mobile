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

## 2. Planned repo layout

```
applivery-soar-agent-mobile/
  lib/                        # Shared Dart: UI, state, networking, models
    main.dart
    config/                   # ManagedConfig model + platform-channel bridge
    status/                   # Compliance status screen + Force Report/Evaluate
    identity/                 # mTLS enrollment/renewal (Dart orchestration; native does the crypto)
    checks/                   # Custom Device Checks: polling + result submission
    api/                      # HTTP client for the SOAR backend device-data endpoints
  ios/                        # Generated by `flutter create` (see README) + platform-channel Swift code
  android/                    # Generated by `flutter create` (see README) + platform-channel Kotlin code
  .github/workflows/          # CI — build verification, same "no local toolchain" story as the other repos
  pubspec.yaml
  README.md
  ARCHITECTURE.md
```

`ios/` and `android/` are intentionally not hand-authored in this pass — see README.md's "Getting started"
section for why, and the exact command to generate them.

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
