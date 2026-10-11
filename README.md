# Paint Patch

**Pitch:** Offline iPhone paint-sampling and touch-up companion for renters and DIY decorators: compare wall swatches, record real can labels and finishes, then find the right touch-up record without accounts.

## Why / for whom

A photo of a painted wall is not a reliable color measurement, and a forgotten can label makes small repairs harder. Home painters can keep room-by-room sample boards with photos, lighting notes, actual brand/color codes transcribed from cans, finish/sheen and where a swatch was tested. It is a record and comparison aid, not an automatic paint matcher.

## Intended workflow

Create a room; add a paint candidate with a label/photo, optional manually typed color code, finish and wall location. Photograph a small test patch at different times, explicitly mark lighting, compare candidate cards side by side, then mark a chosen paint and log the actual can/lot and touch-up date. Revisit the room to find the can label and patch history. In a future iPhone Duo layout, the wall image and swatch gallery stay on one display while a persistent finish/lighting/control tray occupies the other; today the same workflow is a single-screen iPhone app behind `PaintWorkspaceLayout`. Native fold APIs do not exist yet; adapt the seam when supported, without enabling iPad support by inference.

## MVP

- Room, candidate, observed patch, selected finish and can-label records stored locally; no inferred manufacturer color matches.
- Side-by-side photo and typed-code comparison with explicit lighting provenance; unknown code/finish stays unknown, not an approximate match.
- Reversible selection and append-only touch-up events; optional user-owned photos.
- Versioned JSON backup with import preview and CSV room/can inventory export. Optional Photos picker import; camera permission only when the user invokes capture.
- Dynamic Type, VoiceOver labels, contrast-safe swatch text, color-independent selection cues, and one-hand controls.

## Platform and privacy

Native Swift (SwiftUI/UIKit) iPhone-only app, built with iOS 26+ SDK; Xcode 26.0.1 (17A400), Swift 6 planning pin. `TARGETED_DEVICE_FAMILY = 1` in every app configuration, bundle `com.infinityball.paintpatch` as `PRODUCT_BUNDLE_IDENTIFIER`; native iPad support is disabled. Verify built `UIDeviceFamily == [1]` on Apple CI; Linux source checks are not archive evidence. No Android; no Flutter, React Native, Expo, Kotlin Multiplatform, .NET MAUI, Unity. iPad layout is opt-in only. No login, cloud, trackers, or network; locally stored text and photos are exportable, and photo access is limited to explicit picker selection. Avoid claiming that digital photos or phone screens reproduce physical paint color; consult physical samples before buying or applying paint. No structural or hazardous-material advice.

## Status and milestones

Documentation/backlog scaffold only. No Swift app, Xcode project, `AppStore/icon.png`, CI, archive, or TestFlight build yet. First create the native shell, then domain/store, recording flow, accessible comparison, exports, and release artifacts. `AppStore/description.txt` is draft listing copy that must be reviewed against real shipping behavior. Once the app skeleton exists, generate a real `AppStore/icon.png` using `hermes-image-gen` after reading repo and listing; wire it into the Xcode asset catalog. No placeholder is acceptable.

## Build quickstart (once issue #1 lands)

Open the Xcode project with the pinned Xcode 26.0.1 and build an iPhone simulator target with the iOS 26+ SDK. Until then there is no application build/test command. The Swift package domain tests and Apple simulator journey will be specified in the project skeleton issue; do not report them as run now.

## Distribution

App Store Connect registration: `CREATED com.infinityball.paintpatch`. GitHub Actions secrets configured by name: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` (`ASC_TEAM_ID` is the signing team). The packaging issue must port `rwrife/cook-console` `.github/workflows/release.yml`: `v*` tag/manual dispatch on macos-26, iOS 26+ SDK enforcement, signed IPA archive/export, TestFlight upload using the App Store Connect API and those four secrets, processing check, and GitHub release. No secret values or release claims appear in this scaffold.
