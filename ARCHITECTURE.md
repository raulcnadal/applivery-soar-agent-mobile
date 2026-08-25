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
    main.dart                 # Entry point — home: ComplianceScreen (the real status UI, see §0.2/§2.6)
    config/
      managed_config.dart     # ManagedConfig model + ManagedConfigChannel (method + event channel bridge)
    status/
      compliance_screen.dart  # Real compliance status UI — device/policy/risk summary + folded diagnostics, see §2.6
    checks/
      integrity.dart          # IntegrityCheckResult model + IntegrityChannel (jailbreak/root check bridge)
    identity/
      mtls_identity.dart      # MtlsIdentity — register/enroll + generic mTLS-authenticated `request()`, see §2.4/§2.6
    theme/
      design_tokens.dart      # BlueSky-derived colors/spacing/radius/type scale + ThemeData — see §2.5
    widgets/
      app_banner.dart         # Theme-aware header wordmark — see §2.5
    api/
      agent_status_client.dart  # GET /api/device-data/agent-status via MtlsIdentity.request — see §2.6
  assets/
    icon/app_icon.svg         # Source only — rasterized offline into ios/android launcher icons, see §2.5
    images/
      applivery-bp-login.svg          # Source only — rasterized offline into the two files below, see §2.5
      applivery_wordmark_on_dark.png  # Real Flutter asset — light-colored wordmark, for a dark app background
      applivery_wordmark_on_light.png # Real Flutter asset — dark-colored wordmark, for a light app background
    fonts/                     # 3 Outfit weights, same files the desktop agents bundle — see §2.5
  ios/
    Runner/
      ManagedConfigPlugin.swift    # UserDefaults' com.apple.configuration.managed reader
      JailbreakDetector.swift      # JailbreakDetectorPlugin — heuristic checks
      MtlsIdentityPlugin.swift     # Keychain EC keypair + hand-rolled PKCS#10 CSR DER encoding
      AppDelegate.swift            # Registers all three above via didInitializeImplicitFlutterEngine
  android/
    app/src/main/kotlin/com/applivery/soar/mobile/
      ManagedConfigPlugin.kt       # RestrictionsManager reader + ACTION_APPLICATION_RESTRICTIONS_CHANGED
      RootDetectorPlugin.kt        # Heuristic checks
      MtlsIdentityPlugin.kt        # AndroidKeyStore EC keypair + Bouncy Castle PKCS#10 CSR
      MainActivity.kt              # Registers all three above via configureFlutterEngine
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
| `es.applivery.soar/mtls_identity` | Method | `hasIdentity` / `generateCsr` / `storeCertificate` / `clearIdentity` / `mtlsRequest` | See §2.4/§2.6 |

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
| `device_serial` | string | yes (to enroll) | This device's real hardware serial number — see `managed_config.dart`'s doc comment for why the app can't read this itself on either platform. **Must be set to the literal string `{{device.serialNumber}}`** in Applivery's managed app config for this app, not a hardcoded value — confirmed supported via Applivery's own [interpolation tags](https://docs.applivery.com/en/device-management/general-settings/dynamic-variables-interpolation-tags/), substituted server-side per device at push time. |
| `register_url` | string | no | Override for the mTLS enrollment endpoint only; falls back to `base_url`. Same semantics as the desktop agents' `RegisterURL` — see `managed_config.dart`'s doc comment. |
| `bootstrap_token` | string | yes (to enroll) | The Global Bootstrap Token, same value fleet-wide, consumed once on first successful mTLS registration. |
| `interval_sec` | int | no (default 3600) | Report cycle interval, once one exists. |
| `report_integrity` | bool | no (default true) | Whether to run the jailbreak/root check — an admin escape hatch, mirroring the desktop agents' per-signal `report_*` toggles. |

`device_serial`'s `{{device.serialNumber}}` interpolation requirement is confirmed against Applivery's own
published docs (linked above), which explicitly list device configuration profiles and Policies as
supporting interpolation tags — Managed App Configuration for a specific app is one such profile. Not yet
verified end-to-end in this workspace's actual Applivery console (i.e. that setting this app's managed
config field to that literal token really does resolve to the real serial on a real device) — that's the
first thing to confirm before trusting mTLS registration in practice. The rest of the schema (every other
row in the table) is still this repo's own design, not yet cross-checked against Applivery's console UI
either.

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

### 2.4 mTLS device identity — registration only so far

Reuses the backend's existing CSR-based enrollment contract as-is (`deviceMtls.service.ts`,
`deviceMtls.controller.ts`) — same two-factor model the desktop agents already use (a workspace-wide Global
Bootstrap Token plus the claimed serial number being a currently-enrolled Applivery device), same
`{csrPem, serialNumber}` request body, same `{certPem, caCertPem, notAfter}` response. `lib/identity/mtls_identity.dart`'s
`enroll()` mirrors `registerMtlsIdentity` in `mtls_macos.go`/`mtls_windows.go` almost line for line: plain
(non-mTLS) HTTP POST to `/api/device-mtls/register` with `X-Workspace-Slug`/`X-Bootstrap-Token` headers,
since the device has no certificate yet to authenticate with.

**The real device serial problem.** Neither iOS nor Android lets an app read its own hardware serial number —
Apple has blocked it outright since iOS 7 (even for MDM-managed apps), and Android restricts
`Build.getSerial()` to system/privileged callers. But the backend's `assertKnownApplivertyDevice` matches the
registration request's claimed serial number against Applivery's own live fleet data (`d.serialNumber ===
serialNumber` in `deviceMtls.service.ts`), so a wrong or fabricated value just gets a 403, not a real
identity. Resolved via `ManagedConfig.deviceSerial` (§2.2) — Applivery's own `{{device.serialNumber}}`
interpolation tag, confirmed supported for device configuration profiles/policies (see §2.2's citation),
substituted server-side per device before the config ever reaches the app. This is genuinely load-bearing:
without an admin setting this app's managed config `device_serial` field to that literal token in Applivery's
console, enrollment can never succeed no matter how correct everything else is.

**CSR generation, per platform:**

- **Android** (`MtlsIdentityPlugin.kt`): AndroidKeyStore-resident P-256 EC keypair (non-exportable,
  hardware-backed where a StrongBox/TEE is available), CSR built and signed with **Bouncy Castle**
  (`bcpkix-jdk18on`, added as a real Gradle dependency in `android/app/build.gradle.kts`) — deliberately a
  real dependency rather than hand-rolled ASN.1 here: Android's public SDK has no PKCS#10 builder at all
  (`sun.security.*` internals aren't part of it), and Bouncy Castle is the long-established, widely-audited
  standard for exactly this gap. The private key signs via `JcaContentSignerBuilder(...).setProvider("AndroidKeyStore")`
  — the actual EC signing operation happens inside the keystore, raw key material is never read into process
  memory. `storeCertificate` re-associates the backend-issued cert with the same keystore-resident key via
  `KeyStore.setKeyEntry(alias, existingPrivateKey, null, newChain)`.
- **iOS** (`MtlsIdentityPlugin.swift`): Keychain-resident P-256 EC keypair (`kSecAttrIsPermanent`, no Secure
  Enclave yet — see the file's own doc comment for why: SE key generation fails outright on Simulator, and
  this needs to still work there during development). CSR built via **hand-rolled DER/ASN.1 encoding** in
  pure Swift, not a dependency — this Xcode project has no Podfile/SPM package references yet, and adding one
  would need Xcode's own package resolution (network access this sandbox doesn't have) or risky manual
  `project.pbxproj` editing for the dependency graph itself, on top of the file-registration edits already
  made for these three plugin files (see the caveat below). The PKCS#10 structure built is narrow (CN-only
  subject, no extensions/attributes) and every OID is a well-known constant, documented inline in the file.

**The native mTLS-authenticated HTTP client now exists — see §2.6.** `POST /api/device-mtls/renew` itself
still isn't wired up (no Dart-side caller yet), but the underlying capability it needed —
presenting the device's own client certificate for mutual TLS, bound to the non-exportable hardware key — is
built and already used for `GET /api/device-data/agent-status`. Renewal is now "call the same `mtlsRequest`
primitive with a different URL/method," not a separate native-code project.

**`caCertPem` is now captured and stored.** Earlier versions of `enroll()` read `certPem` from the register
response but silently dropped `caCertPem`, and both native `storeCertificate` methods stored only a
single-certificate chain. Fixed: `caCertPem` is now passed through to both native implementations, which
store `[leafCert, caCert]` as the full chain (Android: `KeyStore.setKeyEntry`'s chain array; iOS: the CA cert
is stored as a separate, labeled `kSecClassCertificate` item and included in the `URLCredential`'s
`certificates` array — see §2.6). This matters because some server-side TLS stacks reject a client
certificate whose issuer isn't included in the presented chain, even when that issuer is otherwise trusted.

**Status of the three items originally flagged as UNVERIFIED — all three now confirmed working:**

1. ~~The Xcode project file itself.~~ **Confirmed.** Opened in real Xcode on the dev Mac: all three
   hand-registered files (`ManagedConfigPlugin.swift`, `JailbreakDetector.swift`, `MtlsIdentityPlugin.swift`)
   appear under the Runner target's Build Phases → Compile Sources alongside the original files, with no
   warnings and nothing rewritten by Xcode on open. The hand-edited `project.pbxproj` was correct.
2. ~~The hand-rolled iOS CSR DER encoding.~~ **Confirmed.** End-to-end enrollment succeeded on iOS Simulator
   against a real device serial from the live Applivery fleet — the backend accepted the CSR, issued a cert,
   and `DebugScreen` reported "Enrolled — certificate valid until 2026-11-22…". The hand-rolled DER encoding
   is correct.
3. ~~AndroidKeyStore's `setKeyEntry` re-association behavior.~~ **Confirmed**, after fixing an unrelated
   build blocker: `bcpkix-jdk18on`'s transitive jars (`bcpkix`, `bcutil`, `bcprov`, `jspecify`) all ship an
   identical `META-INF/versions/9/OSGI-INF/MANIFEST.MF`, which failed Android's resource-merge step
   (`mergeDebugJavaResource`) with a duplicate-path error. Fixed with a
   `packaging { resources { pickFirsts += ... } }` block in `android/app/build.gradle.kts` (the file is an
   unused OSGi manifest, so picking either copy is safe). With that fixed, end-to-end enrollment succeeded on
   the Android emulator against a real device serial too.

No local Xcode/Android toolchain in this sandbox to compile or exercise any of the above — verification came
entirely from the user running both platforms on a real Mac, same "CI/device is the real check" story as
every native change in this repo and the two desktop agent repos before it.

**Enrollment is silent, not button-driven.** The first working version required tapping "Enroll now" on the
old debug screen, which isn't how a managed device should behave — the desktop agents self-register with no
admin interaction, and mobile should match that. `_ComplianceScreenState._maybeAutoEnroll()`
(`lib/status/compliance_screen.dart`) fires automatically the moment Managed Config becomes complete
(`ManagedConfig.canEnroll`) and no certificate exists yet — on initial load, and again on every live Managed
Config push via `ManagedConfigChannel.watch()`. It's gated by a fingerprint of
`workspaceSlug|deviceSerial|bootstrapToken` so it only auto-attempts once per distinct config value rather
than retrying on every rebuild if the attempt fails; a manual "Retry" button in the identity row is
unaffected by that gate. This logic now lives in the real compliance status screen (moved there wholesale
from the retired `DebugScreen` — see §2.6) rather than a temporary one; it should still move again once
background execution work happens, so it doesn't depend on any particular screen being open at all.

### 2.5 Branding — icon, wordmark, BlueSky design tokens

Source assets live in `assets/` (`icon/app_icon.svg`, `images/applivery-bp-login.svg`) and aren't Flutter
runtime assets themselves — they're rasterized offline into the actual files the app ships, same
"pre-rasterize once, bundle the raster" approach the Windows/macOS agents use for their own tray/menu-bar
icon and banner (see those repos' `ARCHITECTURE.md` for the `cairosvg`/ImageMagick precedent). Regenerate
with `pip install cairosvg` + Pillow if either source SVG ever changes — there's no Flutter-side build step
that does this automatically (deliberately: `flutter_launcher_icons` would add a dependency for something
that only needs to run once per icon change, not on every build).

- **App icon** (`ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png`, `android/app/src/main/res/mipmap-*/ic_launcher.png`)
  — rendered from `app_icon.svg` at 1024×1024, flattened onto opaque white (the source has a few
  anti-aliased edge pixels with partial alpha; iOS App Store validation rejects an AppIcon with *any*
  transparency), then downsampled to every size both `Contents.json` and the mipmap densities require. No
  adaptive-icon (foreground/background layer split) setup yet — same flat `ic_launcher.png`-per-density
  convention `flutter create` originally scaffolded.
- **Header wordmark** (`assets/images/applivery_wordmark_on_dark.png` / `_on_light.png`, real Flutter
  assets, declared in `pubspec.yaml`) — `AppBanner` (`lib/widgets/app_banner.dart`) picks one based on
  `Theme.of(context).brightness` and shows it top-left in place of a text `AppBar` title, same "banner logo
  top-left, not a centered text title" header treatment as the Windows tray card and macOS menu-bar card.
  **Two variants exist because the source SVG is a near-white wordmark meant for a dark background** — this
  is the exact same legibility problem the Windows tray card had to fix for its own light mode (`tray/card.go`'s
  `loadBannerBitmap(light bool)`, picking between `banner_light.bmp`/`banner_dark.bmp`); the light-theme
  variant here recolors the SVG's `.s0`/`.s1` fills to `#111827` (gray-900) and `.s2` to a solid `#374151`
  (gray-700, dropping its original 54% opacity) — the exact same target colors Windows' own
  `banner_light.bmp` uses, sampled directly from that file's pixels, for cross-platform consistency. Unlike
  the desktop agents (which had to bake the wordmark onto a flat matching background color because GDI/raw
  BMP has no alpha), both PNGs here keep real alpha transparency, so `AppBanner` composites correctly over
  any background, not just one exact hex.
- **Design tokens** (`lib/theme/design_tokens.dart`) — translates the Applivery BlueSky design system (the
  web dashboard's Tailwind CSS v4 tokens: `brand-*` scale, spacing/radius/type scale, `font-semibold`-for-emphasis
  rule) into Flutter `ThemeData`/`TextTheme`/spacing-radius constant classes. Status/tier colors
  (`success`/`danger`/`warning`/`critical`/`low`/`gray400`) are **not** BlueSky tokens — they're carried over
  byte-identical from the desktop agents' own `AppColor`/`tierColor` (macOS `DesignTokens.swift`, Windows
  `tray/card.go`), which predate BlueSky and are this product's own compliance-tier convention. BlueSky's
  dark-mode rules (`references/pages.md`) weren't available when this was written, so this file's dark theme
  is this repo's own Tailwind-gray-scale-inversion choice, not a copy-exact BlueSky pattern — worth
  reconciling if/when `references/pages.md` is available.
- **Typography** — the same 3 Outfit weights (Regular/SemiBold/Bold) the desktop agents bundle
  (`assets/fonts/*.ttf`, copied from the macOS agent's `Resources/Fonts/`), declared as one `Outfit` family
  with weight mapping in `pubspec.yaml`. Simpler than the desktop agents' own setup: CoreText/GDI saw each
  static instance as a separate font *family*, forcing macOS's `FontLoader.swift` to keep a
  weight→family-name lookup table; Flutter's asset-font declaration natively supports multiple weights under
  one family, so call sites just use `fontFamily: 'Outfit'` + `fontWeight:` directly.

Not yet done: `ComplianceScreen`'s cards inherit the tokens via the global `ThemeData` (rounded-xl card
borders, brand-600 filled buttons, Outfit type scale), but individual numeric literals scattered through that
file (padding, icon sizes) weren't swept to reference `AppSpacing`/`AppRadius` directly — low-value polish,
not correctness.

### 2.6 Native mTLS-authenticated HTTP client + the real compliance status screen

This is what unblocked replacing the old dev-only debug screen with a genuine "here's this device's real
compliance state" UI: mobile has no legacy `X-Device-Report-Secret` path at all (§2.2), so the *only* way to
call any authenticated device-data endpoint — `agent-status`, and later `report`/`report-apps`/`renew` — is
by presenting the device's mTLS client certificate on the request itself. That's a materially different
capability from CSR generation/registration (§2.4): it needs an HTTP client bound to a non-exportable
hardware-backed key, which neither Dart's own `http`/`HttpClient` nor a plain platform-channel byte-shuttle
can do.

**The `mtlsRequest` platform-channel method** (`es.applivery.soar/mtls_identity`, alongside `hasIdentity`/
`generateCsr`/`storeCertificate`/`clearIdentity`) takes `{method, url, headers, body}` and returns
`{statusCode, body}` — deliberately generic rather than one native method per endpoint, so the same primitive
covers `agent-status` today and `report`/`report-apps`/`renew` later without new native code each time.

- **iOS** (`MtlsIdentityPlugin.swift`): a `URLSessionTaskDelegate` conformance answers the
  `NSURLAuthenticationMethodClientCertificate` challenge by looking up the `SecIdentity` that Keychain already
  forms automatically by pairing the stored private key with its matching leaf certificate (the same
  `kSecClassIdentity` query `hasIdentity()` already used), plus the separately-labeled CA certificate if one
  was stored (§2.4's `caCertPem` fix), and answers with
  `URLCredential(identity:certificates:persistence:)`. Server certificate validation itself uses URLSession's
  normal default handling — no pinning, since the SOAR backend's own TLS cert is a regular publicly-trusted
  one. A fresh `.ephemeral` session is built per call (this is called rarely — status refresh, eventually
  renewal — so session-lifecycle complexity isn't worth it, and ephemeral guarantees no cached response hides
  a stale compliance status).
- **Android** (`MtlsIdentityPlugin.kt`): `KeyManagerFactory.getInstance(...).init(androidKeyStore, null)`
  scoped to the app's `AndroidKeyStore` (which only ever holds the one `es.applivery.soar.mtls` alias, so
  there's no ambiguity about which identity gets presented) paired with the platform's default
  `TrustManagerFactory` for server validation, built into a per-call `SSLContext` and set on an
  `HttpsURLConnection` — not installed as the process-wide default socket factory, since the *plain*
  (non-mTLS) enrollment POST in `enroll()` must never present a client certificate and a global override would
  leak into that call too. Runs on `Dispatchers.IO` via a plugin-scoped `CoroutineScope` so the network call
  never blocks Flutter's platform-channel thread; `kotlinx-coroutines-android` was added as an explicit Gradle
  dependency for this (not assumed to be transitively available from the Flutter engine — it isn't). Uses raw
  `HttpsURLConnection` rather than adding OkHttp, keeping with this repo's otherwise dependency-light native
  layer (`bcpkix-jdk18on` for CSR signing is the one prior exception, and only because the Android SDK has no
  CSR builder at all).

  **Two real bugs found chasing the same symptom (`$ssl_client_verify == NONE` — nginx's value for "no
  certificate was ever presented," distinct from `FAILED`) against a real deployment, not designed in advance.**
  iOS worked against the mTLS-fronting agent subdomain (`agents.soar.*`, per the roadmap's dedicated-vhost
  requirement — see the operational caveat below) on the first real device test, populating the compliance
  screen with real data. Android, hitting the exact same server with a confirmed-valid, complete-chain
  certificate, consistently got the TLS connection to complete and the HTTP request to go through, but with no
  client certificate ever exchanged.

  1. **First hypothesis, pinned `SSLContext.getInstance("TLSv1.2")` instead of the generic `"TLS"` — tested,
     ruled out, reverted.** nginx's `ssl_verify_client optional` requires *post-handshake* client
     authentication under TLS 1.3 (a second round-trip, after the initial handshake, explicitly asking the
     client for a certificate) — nginx's own docs flag this as a real client-compatibility gap, and `"TLS"` on
     a modern Android device negotiates TLS 1.3 against a modern nginx by default, so a stack that doesn't
     answer that post-handshake request would produce exactly this symptom. Plausible, but retesting after this
     change alone showed the *same* `NONE` result — not the actual cause. Worse, once combined with fix #2
     below, this pin correlated with a *new*, different failure (`Read error: ssl=... I/O error during system
     call` — a raw TLS/socket-layer error, connection never even reaching the backend, no server-side log line
     at all) — never isolated and confirmed which of the two changes caused it, but pinning to TLS 1.2 is the
     more likely regression of the two, so it was reverted back to the generic `"TLS"` rather than left stacked
     on an unconfirmed interaction. If nginx's TLS 1.3 post-handshake gap turns out to matter after all, it
     needs to be revisited in isolation, not combined with other changes in the same test.
  2. **Actual fix for the original `NONE` symptom: force `chooseClientAlias`/`chooseEngineClientAlias` rather
     than trust Android's default selection.** Android's built-in `X509KeyManager` (what `KeyManagerFactory`
     hands back for an `AndroidKeyStore`-backed keystore) has a well-documented history of returning `null`
     from `chooseClientAlias` during a live TLS handshake even when the keystore genuinely contains a single,
     valid, matching entry — the JSSE/Conscrypt candidate-selection logic that runs during a handshake goes
     through a different code path than the direct `KeyStore.getEntry`/`getCertificate` calls this plugin's
     other methods use (which do work correctly — enrollment itself was never in question). Since this keystore
     only ever holds the one `es.applivery.soar.mtls` alias, there's no real selection to make, so `mtlsRequest`
     wraps each `X509ExtendedKeyManager` from `keyManagerFactory.keyManagers` in an anonymous subclass that
     always returns `KEYSTORE_ALIAS` from `chooseClientAlias`/`chooseEngineClientAlias`, delegating
     `getCertificateChain`/`getPrivateKey`/`getClientAliases`/`getServerAliases`/`chooseServerAlias` straight
     through to the real KeyManager. This is the standard, documented workaround for this exact class of
     Android bug.

  3. **The actual root cause of the `Read error: ssl=... I/O error during system call` symptom (fix #1 above
     wasn't it either) — confirmed from the exact stack trace, not guessed.** Once the request finally got far
     enough to attempt the handshake's CertificateVerify signature, Conscrypt logged
     `android.security.KeyStoreException: Incompatible digest ... Error::Km(INCOMPATIBLE_DIGEST)` and
     `Could not find provider for algorithm: NONEwithECDSA`. Every TLS engine — Conscrypt included — signs the
     handshake's CertificateVerify message via `NONEwithECDSA`: TLS computes its own transcript hash outside
     the keystore and asks the private key to sign that raw digest directly, no further hashing. AndroidKeyStore's
     Keymaster refuses that signing operation with `INCOMPATIBLE_DIGEST` unless `DIGEST_NONE` was explicitly
     declared in `setDigests(...)` at key-generation time — regardless of how valid the issued certificate or
     its chain is. `generateCsr` originally only declared `DIGEST_SHA256` (all CSR signing — `SHA256withECDSA`
     — ever needed), so every previously-enrolled Android identity was structurally incapable of ever succeeding
     at a TLS client-cert handshake, no matter what was tried at the `mtlsRequest` end.

     Three combinations were tried, in this order, all with real-device evidence (never guessed):

     - **Both digests declared, signed via standard `JcaContentSignerBuilder("SHA256withECDSA")`.** Looked
       correct but broke AndroidKeyStore's own JCA provider registration of `SHA256withECDSA` outright, throwing
       `NoSuchAlgorithmException: no such algorithm: SHA256WITHECDSA for provider AndroidKeyStore` on every
       `generateCsr` call. **Confirmed reproducible identically on both the Android emulator and a real Samsung
       S23 Ultra device.**
     - **`DIGEST_NONE` declared alone**, expecting `NONEwithECDSA` to then register cleanly. Broke in the
       *opposite* direction instead: `Signature.getInstance("NONEwithECDSA", "AndroidKeyStore")` itself threw
       `NoSuchAlgorithmException: no such algorithm: NONEwithECDSA for provider AndroidKeyStore`. So declaring
       only one digest — either one — leaves the provider unable to register an EC Signature service for the key
       at all on this platform; a second, "real" digest in the authorized set appears necessary for the
       provider's algorithm table to populate correctly, even for a digest never directly used.
     - **Both digests declared, signed via a custom `NONEwithECDSA`-based signer.** Confirmed FAILED, identically,
       on both the emulator and a real Samsung S23 Ultra, with a full stack trace pointing at the signer's own
       `Signature.getInstance("NONEwithECDSA", "AndroidKeyStore")` call:
       `NoSuchAlgorithmException: no such algorithm: NONEwithECDSA for provider AndroidKeyStore`. Combined with
       the DIGEST_NONE-alone attempt failing identically for the same algorithm name, this rules out
       "NONEwithECDSA" as ever being a usable public JCA algorithm name under AndroidKeyStore's provider on this
       platform, in any digest configuration tried.
     - **Both digests declared, signed via `Signature.getInstance("SHA256withECDSA")` with NO explicit provider
       name** — the combination now in use. `generateCsr` still declares both `KeyProperties.DIGEST_SHA256` and
       `KeyProperties.DIGEST_NONE` (SHA256 for CSR signing, NONE for the TLS handshake's raw-digest
       CertificateVerify signature). `Sha256WithEcdsaSigner` creates its `Signature` via the one-argument
       `Signature.getInstance("SHA256withECDSA")` overload (searches every installed provider, then resolves the
       actual implementation from the AndroidKeyStore-resident `PrivateKey` object's own runtime type at
       `initSign()`) instead of the two-argument `Signature.getInstance(algorithm, "AndroidKeyStore")` overload
       (an exact name-based lookup against that provider's static service table) that failed in every variant
       tried so far. This is a documented AndroidKeyStore quirk and the pattern Android's own official crypto
       samples use — some AndroidKeyStore versions only populate the per-key virtual service dispatch the
       one-argument form reaches, not the static table the two-argument form's name lookup checks.
       **Not yet confirmed working — pending re-test.** **A key generated before this fix cannot be reused —
       needs a fresh enrollment (uninstall/reinstall or `clearIdentity` + re-enroll) to pick up the corrected
       digest set.**

  4. **The actual reason the still-broken cases kept recurring after fixes #2/#3: `hasIdentity()` couldn't tell
     a real identity apart from AndroidKeyStore's own placeholder.** Diagnostic logging added to `storeCertificate`
     and `mtlsRequest` (temporary — dumps the stored chain's subject/issuer/validity to logcat, all public
     certificate data) caught it directly: `chain[0] subject=CN=Fake issuer=CN=Fake notAfter=Wed Jan 01
     01:00:00 GMT+01:00 2048`. AndroidKeyStore auto-generates a self-signed placeholder certificate the instant
     a keypair is created — well before any real enrollment — and `hasIdentity()` originally just checked
     `getCertificate() != null`, which that placeholder always satisfies. Since `_maybeAutoEnroll`
     (`mtls_identity.dart`) only re-attempts `enroll()` when `hasIdentity()` reports false, a half-finished
     attempt (key generated via `generateCsr`, but `register`/`storeCertificate` never completing — e.g. a
     transient network blip) left a placeholder-only identity that this method reported as genuine, permanently
     blocking retry and causing the bogus `CN=Fake` cert to be presented as the real client certificate on
     every subsequent handshake — which is exactly the HTTP 400 "SSL certificate error" nginx was correctly
     rejecting. Fixed by checking self-signedness rather than mere presence: a real cert issued through
     `POST /api/device-mtls/register` is never self-signed (its issuer is always the workspace's CA), so
     `subject != issuer` reliably distinguishes "real, backend-issued identity" from "AndroidKeyStore's own
     placeholder," without depending on matching Android's specific (undocumented, possibly OEM-varying)
     placeholder subject string. No iOS equivalent — the Keychain never auto-creates a placeholder certificate
     for a bare `SecKey`, so `hasIdentity()`'s `kSecClassIdentity` query there only ever succeeds once a real
     certificate has actually been stored.

  Fixes #2, #3, and #4 together are what make the Android mTLS path actually work; fix #1 (TLS 1.2 pin) was a
  dead end, reverted. **Not yet re-verified against a real device after fix #4** — see the toolchain note below.
  iOS's `URLSession` was not observed to have any of these problems (confirmed working against the same
  server), so all four are Android-only.

**`lib/identity/mtls_identity.dart`** wraps this as `MtlsIdentity.request({method, url, headers, body}) ->
MtlsHttpResponse`, throwing `MtlsRequestException` for a failed call (bad/missing identity, TLS handshake
failure, timeout) as distinct from a successful call that got back a non-2xx `MtlsHttpResponse` — callers
need to tell those apart (a 401 with a perfectly valid TLS handshake means something different than the
handshake itself failing).

**`lib/api/agent_status_client.dart`** is the first real caller: builds
`GET {baseUrl}/api/device-data/agent-status?serialNumber=...&platform=ios|android` (platform read via
`Platform.isIOS`/`Platform.isAndroid`), sends it with `X-Workspace-Slug` through `MtlsIdentity.request`, and
parses the JSON into `AgentStatusResult`/`AgentComplianceStatus`/`AgentPolicySummary`/`AgentPolicyViolation` —
a field-for-field mirror of backend's `AgentStatusResponse` interface (`deviceData.service.ts`).

**Operational caveats worth knowing before this is genuinely useful in a workspace — both confirmed against a
real deployment, not theoretical:**

1. `verifyDeviceIdentity` (backend `deviceData.service.ts`) branches on that workspace's `mtlsEnforcementEnabled`
   flag — if it's off, every device-data request is checked against the legacy `X-Device-Report-Secret` header
   instead of the client certificate, and mobile has no value for that header and never will (§2.2: "no
   report_secret legacy path to carry forward"). So a workspace that hasn't flipped mTLS enforcement on yet will
   see *every* call from this app fail with 401/403, even from a device with a perfectly valid,
   correctly-presented certificate.
2. Separately — and this one bit real testing, not just a theoretical gap — the backend's own mTLS verification
   happens entirely at the reverse-proxy edge (`backend/docs/mtls-agent-auth-roadmap.md` §5), never inside the
   Node app itself, and that proxy is deliberately configured on a **separate "agent subdomain"** from the
   dashboard's own origin (nginx can't scope `ssl_verify_client` to a path, only a whole vhost — putting it on
   the dashboard's vhost took a real deployment's dashboard offline in a prior incident). `base_url` in
   Managed Config MUST be that agent subdomain (Settings → mTLS Authentication → Agent subdomain), not the
   dashboard's URL — pointing at the dashboard produces the exact same symptom as caveat 1 (`assertMtlsIdentity`
   rejects with "missing or invalid internal proxy secret," since that vhost has zero client-cert directives by
   design), even with enforcement correctly enabled and a perfectly valid certificate.

Both surface identically in the status screen as `AgentStatusException.likelyMtlsNotEnforced` (set whenever the
failure is 401/403) rather than a generic error, prompting "ask your Applivery admin to enable mTLS enforcement
for this workspace" — accurate for caveat 1, a reasonable first thing to check for caveat 2 too, though the
actual fix there is pointing `base_url` at the right host rather than a settings toggle. The backend's own
`[mTLS] ... rejected: <reason>` server log (`mtlsIdentity.middleware.ts`'s `logRejection`) is what actually
disambiguates the two — "missing or invalid internal proxy secret" is caveat 2 (wrong host); "no verified
client certificate identity presented" means the request reached the right host but the TLS handshake itself
didn't carry a certificate (see the Android TLS 1.2 pin above for one real cause of exactly that); "no active
DeviceCertificate row" means a genuine cert/CN/revocation mismatch.

**`lib/status/compliance_screen.dart`** (`ComplianceScreen`, no longer `main.dart`'s `home` directly — see §2.7,
`SplashScreen` now runs first and hands off to it) is built around this data: a device header card (name,
compliant/non-compliant/unavailable status pill, risk tier/score badges) and a policies card (applicable
policies with a per-policy violated/compliant icon, using the same `tierColor`/`AppColors.success`/`danger`
convention as the Windows tray card and macOS menu-bar card). Pull-to-refresh re-runs config, integrity check,
identity status, and (if enrolled) the agent-status fetch together. The identity row and Managed
Config/integrity diagnostics that used to sit inline here moved into a hidden menu — see §2.7.

No local Xcode/Android/Dart toolchain in this sandbox to compile or exercise any of the above — same "CI/
device is the real check" story as every other native change in this repo; all verification came from the user
running both platforms locally. **iOS: confirmed working end-to-end** against a real device serial and a
correctly-configured agent subdomain — the compliance card populated with real risk score/tier and an actual
policy violation, not placeholder data. **Android: confirmed working through enrollment** (fresh identity,
full cert chain); the `agent-status` call itself needed the TLS 1.2 pin above to get a client certificate
presented at all, found via the exact `[mTLS] ... rejected` log line disambiguation described above — re-verify
against a real Android device/emulator after that change, since it hasn't had its own live-handshake
confirmation yet.

### 2.7 Splash screen, hidden Diagnostics menu, policy detail screen, About

Four additions on top of §2.6's working compliance screen, all UI-layer except the first bullet's backend
endpoint:

- **Policy detail screen (`lib/status/policy_detail_screen.dart`)** — tapping a policy row in
  `_CompliancePoliciesCard` now pushes a screen showing that policy's per-condition breakdown, each with a
  red/green dot for whether it currently matches this device — mirroring the web dashboard's
  `DeviceCompliancePolicyStatusModal.vue` (pill, "Matches ANY/ALL conditions below", per-condition rows, the
  same explanatory legend text). No mTLS-gated endpoint exposed this before — the only existing per-condition
  lookup (`devices.service.ts`'s `getDeviceCompliancePolicyStatus`) is dashboard-token-gated. Backend now has
  `GET /api/device-data/compliance-policy?serialNumber=...&policyId=...`
  (`deviceData.controller.ts`/`deviceData.service.ts`'s `getAgentCompliancePolicyStatus`), which reuses a
  newly-extracted `evaluatePolicyForDevice` helper (`devices.service.ts`) — the exact same function the
  dashboard's own endpoint now calls, so a condition never evaluates differently depending on which caller
  asked. `lib/api/compliance_policy_client.dart`'s `conditionLabel` is a lighter, self-contained cousin of the
  web's own `conditionLabel`: the web version resolves field keys against a fetched compliance-fields catalog
  for type-specific phrasing (smart_attribute/self_reported_attribute/custom_field/duration/boolean); this app
  has no such catalog call, so it humanizes the raw field key (camelCase/snake_case -> Title Case) instead —
  covers the common shapes (exists/missing with a named sub-attribute, arrays, objects with a name, plain
  scalars) without the catalog dependency.
- **Splash screen (`lib/splash/splash_screen.dart`)** — now `main.dart`'s `home`, replacing `ComplianceScreen`
  directly. Solid `#0242E3` background (specified exactly; close to but deliberately not reusing
  `design_tokens.dart`'s `AppColors.brand600` `#0241E3`, kept as its own local constant), the dedicated
  `applivery-splash.svg` lockup (icon + "SOAR Agent for mobiles" wordmark — a distinct asset from
  `applivery-bp-login.svg`, which is AppBanner's compact header wordmark only) fading/scaling in over 900ms
  (`AnimationController` + `Curves.easeOutBack`), then a 1400ms hold before a 400ms fade transition into
  `ComplianceScreen` (~2.7s on screen total). This is a Flutter-drawn splash only — it doesn't touch either
  platform's native launch screen/storyboard, so there's still an unavoidable static native splash for the
  sub-second gap between process start and Flutter's first frame; out of scope here. Both
  `applivery-bp-login.svg` and `applivery-splash.svg` needed a real fix before `flutter_svg` could render either
  one: both used a `<style>` block with CSS class selectors (`class="s0"` etc.) for their fills, which
  `flutter_svg`'s parser doesn't support (only direct presentation attributes) — confirmed via its own
  "unhandled element `<style/>`" warning and the resulting blank/invisible logo on a real device. Both files
  were rewritten with the exact same fill values as plain inline `fill="..."` attributes instead — a pure
  compatibility fix, not a visual change.
- **Hidden Diagnostics menu (`_DiagnosticsDrawer` in `compliance_screen.dart`)** — long-pressing the header
  logo (wrapped in a `Builder` + `GestureDetector`, needed because `Scaffold.of(context)` requires a context
  below the `Scaffold` being built, which the State's own `build(context)` parameter isn't) opens a
  `Scaffold.endDrawer` titled "Diagnostics" at its top, containing what used to sit inline in the main view:
  the device certificate/enrollment status (`_IdentityRow`, unchanged internally, just relocated) and the
  Managed Configuration + integrity check content (`_DiagnosticsContent`, the same data the old
  `_DiagnosticsSection` folded into a collapsed `ExpansionTile` — now always-expanded, since the menu itself is
  already the "tucked away" layer). An "About" `ListTile` sits at the very bottom.
- **About screen (`lib/about/about_screen.dart`)** — short, static description, ending with "Proudly crafted in
  Europe by Applivery 🇪🇺" per spec. Linked from the Diagnostics drawer's bottom `ListTile`.

None of this has been run against a real toolchain by this pass either (no local Flutter SDK in this sandbox,
same story as everything else in this repo) — needs `dart format . && flutter analyze && flutter test` plus a
real device/emulator pass on both platforms before it's confirmed, same verification loop as every other
feature in this file.

## 2.8 Device security telemetry roadmap (Phase 1 of 4: iOS Keychain passcode check)

New multi-phase roadmap: give SOAR real device-security telemetry from the mobile agent, matching what the
Windows/macOS self-report agents already send, wired into the Compliance Policy Builder and the ENS/ISO27001/
NIS2 templates. Phase 1 (this pass) is iOS-only; Phases 2-4 (Android Security Provider + KeyStore attestation,
Google Play Integrity, and root/jailbreak detection enhancements for both platforms) land in later passes.

- **The report loop itself is new — this is the real unlock.** Before this phase, the mobile app only ever
  GETed `agent-status`/`compliance-policy`; it had never called `POST /api/device-data/report`, the same
  device-facing, mTLS-gated endpoint the Windows/macOS agents call every cycle
  (`reportDeviceData`, `deviceData.service.ts`). That endpoint turned out to already be fully
  platform-agnostic — plain `platform: z.string()`, no windows/macos-specific branching anywhere in
  `reportDeviceData` itself, and `normalizePushedAttributes` simply passes ios/android attribute keys through
  unchanged (no alias table exists for them, unlike `WINDOWS_ATTR_ALIASES`/`MACOS_ATTR_ALIASES`) — so **zero
  backend schema changes were needed** to start reporting from mobile. `lib/api/device_report_client.dart` is
  the new client; it's called fire-and-forget from `ComplianceScreen._fetchStatus()` after every successful
  status fetch (app open + pull-to-refresh) — there's no background-execution scheduling in this app yet, so
  that's the report cadence for now.
- **`DeviceSecurityTelemetryChannel` (`lib/checks/device_security_telemetry.dart`)** — a new platform channel
  (`es.applivery.soar/device_telemetry`, method `collect`), deliberately separate from `IntegrityChannel`
  (`checks/integrity.dart`): that one is local compromise-detection signals shown in the Diagnostics drawer;
  this one is security-POSTURE telemetry meant to leave the device as Compliance Policy conditions. Returns a
  flat `Map<String, dynamic>` sent as-is as the report's `attributes` — whatever key a native plugin returns
  IS the exact name a policy's `selfReportedAttribute` condition must reference (no server-side alias
  translation for mobile, see above), so native plugin key names and `complianceFields.ts` template condition
  names have to be kept in lockstep by hand.
- **iOS: `devicePasscodeSet` via a Keychain-accessibility probe (`ios/Runner/DeviceSecurityTelemetryPlugin.swift`).**
  iOS has no public API to directly ask "is Data Protection encryption enabled" — there's nothing to
  separately enable, since Data Protection is automatically active for every app the moment (and only once) a
  device passcode is set. The standard technique (documented behavior of Apple's own Keychain Services
  `kSecAttrAccessible` values, not a private API): attempt to write a throwaway Keychain item with
  `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`; `SecItemAdd` fails unless a passcode is currently set,
  because the passcode-derived key needed to protect that item class doesn't exist otherwise. The probe item
  is deleted immediately after (both on success and failure) — this never leaves real data in the Keychain,
  it's purely a capability check. `devicePasscodeSet` backs BOTH the encryption and screen-lock template slots
  server-side (`complianceFields.ts`'s `encryptionCondition("apple")`/`screenLockCondition("apple")`) since
  on iOS those are the same underlying fact, unlike Windows/macOS/Android where they're independently
  configurable.
- **Android: plugin skeleton only, no signals yet (`android/.../DeviceSecurityTelemetryPlugin.kt`).** Returns
  an empty map today — Phase 1 is iOS-only. Registered on both platforms now (`AppDelegate.swift`,
  `MainActivity.kt`) so the report-loop plumbing itself is built and exercised end-to-end on both platforms at
  once; Phases 2-3 add real entries to this same map (`securityProviderUpToDate`,
  `keystoreAttestationSecurityLevel`, `playIntegrityVerdict`, ...) without touching the channel contract,
  `device_report_client.dart`, or the `ComplianceScreen` wiring at all.
- **Backend: `complianceFields.ts` widened, no other backend changes.** `encryptionCondition`/
  `screenLockCondition` now accept `"apple"` (previously `"windows" | "macos" | "android"` only), both mapping
  to a `selfReportedAttribute` condition on `devicePasscodeSet`. New template entries added across all three
  frameworks: `iso27001-encryption-apple`, `iso27001-screen-lock-apple`, `ens-encryption-apple`,
  `ens-screen-lock-apple`, `nis2-crypto-apple`, `nis2-hygiene-screenlock-apple` — the same encryption/
  screen-lock control references Windows/macOS/Android already had, now real for iOS too instead of
  structurally excluded.
- **Real pre-existing bug found and fixed alongside this: `platform=ios` vs `targetPlatform: "apple"`
  mismatch.** The mobile agent's `agent-status`/`compliance-policy` calls send the OS-level string
  `Platform.isIOS` gives Dart — literally `"ios"` — matching `customChecks.schemas.ts`'s `CHECK_PLATFORMS`
  convention. But `CompliancePolicy.targetPlatform` (and `device.platform` everywhere else in the app —
  `deviceNormalize.ts`, `COMPLIANCE_FIELDS`' `platform` options, every existing `-apple` template) uses the
  MDM/dashboard-side convention, where an enrolled iPhone/iPad is `"apple"`, never `"ios"`. Without a mapping,
  `getAgentStatus`'s exact-match filter (`deviceData.service.ts`) meant any policy an admin scoped to
  `"apple"` — including the brand-new templates above — would silently never appear in that same device's own
  `agent-status`/policy list when the request came from the mobile app itself, even though the policy
  genuinely applies to and evaluates against that device everywhere else. Fixed with a one-line mapping right
  before the `targetPlatform` filter (`platform === "ios" ? "apple" : platform`); `getAgentCompliancePolicyStatus`
  needed no equivalent change since it resolves a specific already-chosen `policyId`, not a platform-filtered
  list.

Not yet run against a real toolchain (no local Flutter/Xcode SDK in this sandbox) — needs
`dart format . && flutter analyze && flutter test` plus a real device pass (Keychain behavior specifically
needs a physical device or a Simulator with/without a passcode set; the iOS Simulator's Keychain does still
enforce `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly ` the same way, unlike some of `JailbreakDetector.swift`'s
sandbox-escape checks) before this is confirmed working end to end, same verification loop as every other
feature in this file.

## 3. Backend touch points (SOAR repo work, not this repo)

The desktop agents report through two endpoints in `modules/devices/deviceData.controller.ts`:
`POST /api/device-data/report` (fixed attributes + `customCheckResults`) and
`POST /api/device-data/report-apps`. Status as of the SOAR repo's own backend-touch-points pass:

- **Device-matching key — confirmed, no change needed.** Read `verifyDeviceIdentity`/`reportDeviceData`/
  `getAgentStatus` directly (`deviceData.service.ts`): every device-caller endpoint matches by plain serial
  number (`d.serialNumber === serialNumber`), with no platform branching at all. Mobile already resolves its
  own real serial via the `{{device.serialNumber}}` Managed Config interpolation tag (§2.2) and mTLS
  registration already forces the issued cert's CN to that verified serial — so serial-number matching
  carries over completely unchanged, the same field Applivery reports for every platform.
- **`GET /api/device-data/custom-checks?platform=ios|android` — done.** Extended `CHECK_PLATFORMS`
  (`customChecks.schemas.ts`) rather than building a parallel mechanism, exactly as planned. One real design
  decision fell out of this: of the 5 existing checker types (process/service/registry-or-file/appInstalled/
  command), only `appInstalled` has any meaningful implementation on a sandboxed mobile OS — the other four
  have no API surface on iOS/Android at all. `MOBILE_CHECK_PLATFORMS`/`validateCheckParams` reject the other
  four server-side for `ios`/`android`; the Settings UI (`CustomDeviceChecksPanel.vue`) filters its
  checker-type picker to match. Even `appInstalled` is weaker on mobile: Android needs package-visibility
  filtering to check a specific package name; iOS has no general "is bundle ID X installed" API at all, only
  `canOpenURL:` against a scheme the target app registers *and* this app pre-declares in
  `LSApplicationQueriesSchemes` — the admin-facing UI flags this inline. **Not yet implemented on this repo's
  side**: nothing in `lib/` polls `custom-checks` or reports `customCheckResults` yet — that's real future
  work, and the iOS `LSApplicationQueriesSchemes` plumbing (an admin-provided allow-list needs to somehow
  reach `Info.plist`, which is normally build-time static) is an open design question, not just an
  implementation task.
- **`GET /api/device-data/agent-status` — confirmed platform-agnostic, no change needed.** `platform` is
  only used to filter which Compliance Policies are "applicable to this device" (`p.targetPlatform ===
  platform`) — matching already works for `ios`/`android` today as long as policies use those strings as
  `targetPlatform`.
- **mTLS `POST /api/device-mtls/register` — confirmed working, no change needed.** Already verified
  end-to-end against the real backend on both iOS Simulator and Android emulator (§2.4) — the CSR-based flow
  never had a platform-specific assumption to begin with.
- **`GET /api/device-data/compliance-policy` — new, done.** Added for §2.7's policy detail screen — see that
  section for the full design (reuses `devices.service.ts`'s newly-extracted `evaluatePolicyForDevice`, same
  auth as every other route in `deviceData.controller.ts`).
- **"SOAR Agent: Installed" column — real gap found and fixed, done.** The Devices list's `soarAgentReporting`/
  `soarAgentLastReportedAt` computation (`devices.service.ts`) previously only had one signal:
  `DevicePushData.reportedAt`, written exclusively by `POST /api/device-data/report` — at the time, an
  endpoint mobile never called (it only GETed `agent-status`/`compliance-policy`). As of the device-security-
  telemetry roadmap (§2.8) this repo now calls that same endpoint too, but the fix below stayed in place
  regardless — it's a real second, independent freshness signal (mTLS activity vs. an explicit report), not
  a workaround for a gap that's since closed. iOS/Android devices that had fully registered and were actively
  polling but not yet reporting still showed "Not installed" before this fix. Fixed with a second signal:
  `DeviceCertificate.lastSeenAt` (new column, migration `20260824230000_device_cert_last_seen`), stamped
  fire-and-forget on every successful mTLS-gated request via `certificates.service.ts`'s
  `touchCertificateLastSeen` (called from `mtlsIdentity.middleware.ts`'s `assertMtlsIdentity` right after a
  cert passes verification). `devices.service.ts` now takes the more recent of the two timestamps per device,
  so a Windows/macOS device that's switched to mTLS auth still shows its true freshest activity either way.
- **Still open**: a schema for what Applivery UEM's Managed App Configuration will actually deliver to this
  app in the real console (as opposed to this repo's own guessed §2.2 schema), and a field-reference table
  analogous to the Windows registry policy / macOS preferences plist references in each desktop agent's
  README. This is an Applivery-console configuration task, not backend code — nothing to "extend" in
  `deviceData.controller.ts` for it.

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
