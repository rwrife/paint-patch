# Paint Patch plan

## Scope and architecture

A native SwiftUI iPhone-only room paint notebook. `PaintPatchKit` contains Room, Candidate (user-entered brand/code/finish), Observation (photo reference, timestamp, user-typed lighting, surface and optional notes), Selection and TouchUpEvent. Use an append-only change log for selection/touch-up history; never derive exact paint color from a camera image or treat missing codes as matches. GRDB/SQLite or a simpler local file store only if migration/restore tests justify it; source photo files remain local and exportable. `PaintWorkspaceLayout` composes wall/photo gallery and finish/lighting controls into one accessible iPhone view now, with an eventual split across Duo displays when supported by an actual SDK. No fold API dependency or iPad implementation is implied.

## Milestones and dependencies

1. Native Xcode project, Swift 6 domain test target and iOS 26+ SDK CI pin.
2. Local record model with migration, required/optional fields and deterministic unknown-safe comparison.
3. Room/candidate creation, user-owned image selection/camera capture and patch observations.
4. Accessible comparison, explicit selection and touch-up log; `PaintWorkspaceLayout` one-screen seam.
5. Previewed JSON backup/import, CSV export, privacy and consent controls.
6. Domain/restore/UI regression evidence, app listing review, real generated `AppStore/icon.png`, signed release workflow.

## Testing

Pure Swift tests for missing codes, multiple observations under different light, conflicting finish and reversibility; migration and preview-before-restore fixtures. UI journey on iPhone simulator for create room, record two swatches, compare without relying on color alone, touch-up, export/restore. Verify camera and Photos permission denial gracefully; do not require camera for manual records. `TARGETED_DEVICE_FAMILY = 1` in all app configurations and built `UIDeviceFamily == [1]` checked on Apple CI; no native iPad support. Linux structural verification never substitutes for a signed archive or native build. No tests exist yet at scaffold time.

## Packaging

Pin Xcode 26.0.1 (17A400), Swift 6, iOS 26+ SDK and `com.infinityball.paintpatch` across `PRODUCT_BUNDLE_IDENTIFIER`, Info.plist and signing. Secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` are configured on the repository (names only). Port `rwrife/cook-console` `.github/workflows/release.yml`: `v*` tag/manual trigger, macos-26, enforce iOS 26+ SDK, create mode-600 ASC API key, archive/export signed IPA, upload TestFlight via App Store Connect API, wait for processing, publish GitHub release only on real success. Review `AppStore/description.txt` against shipped behavior. Generate `AppStore/icon.png` with `hermes-image-gen` only after repo/listing analysis, verify opaque square edge-to-edge no-text artwork and wire into app icon catalog. No workflow/icon/IPA is scaffolded today.

## Risks and non-goals

Physical swatches under actual lighting remain ground truth; camera white balance, screen calibration, and gloss make automatic color matching unreliable. No paint shopping, paint formula prediction, lead paint/asbestos handling advice, structural renovation guidance, diagnosis or treatment. No network, accounts or cloud. No Android or native iPad support; no Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity. Dual-screen and tablet layouts remain future SDK-dependent design targets, with iPad support requiring explicit user opt-in.
