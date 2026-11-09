# Plan: "Cam18", a film-style camera app for iPhone 17 Pro

## Context
On iOS 27 the iPhone 17 Pro has no Film, Glow or Soft Skin camera styles. Its camera configuration doesn't declare support for them and has none of their tuning, and stock iOS can't change that. So we'll build our own camera app with only Apple's public frameworks. It recreates the looks with our own image processing and keeps the original photo so the look can be changed later. It's an original take on the effects, not a copy of Apple's pipeline, so results will differ from the 18 Pro's.

You build in the cloud on a macOS runner (GitHub Actions) and sideload from Windows, since this PC has no Xcode.

## Approach
- **Language and UI:** Swift 6 and SwiftUI. Target iOS 26 or later so a recent SDK and runner image work.
- **No Xcode on this PC:** the Xcode project is generated from a text `project.yml` using **XcodeGen**, which runs on the CI Mac. Nothing machine-specific is committed.
- **One image pipeline for preview and photos.** Each look is a chain of Core Image filters plus a few custom Metal kernels. The same chain renders:
  - the live preview, from `AVCaptureVideoDataOutput` to an `MTKView`, at reduced resolution
  - the full-resolution photo, from `AVCapturePhotoOutput`, with the camera's normal processing as input
- **"Bake in look" toggle.** It sits in the camera UI and is remembered between launches. It's **off by default**.
  - **Off (editable):** the photo is saved through PhotoKit with the untouched original plus a small JSON *recipe* stored as `PHAdjustmentData`. Reopening the photo in Cam18 loads the recipe so the look can be changed or removed, and **Revert** in the Photos app restores the original.
  - **On (baked):** the rendered photo is saved as a normal new HEIC with no recipe and no original kept. Its metadata keeps camera EXIF and adds the look name. It shows identically everywhere (sharing, other apps, computers), but the look can't be undone.
  - **Indicator:** a small badge in the viewfinder shows the current mode, so you know before you take the shot.

## The looks (all with intensity sliders)
| Look | How it's made |
|---|---|
| **Tone & Color pad** | 2-D control: tone (tone-curve contrast and black lift) by color (saturation/vibrance plus warmth). |
| **Film** | Filmic tone curve (lifted blacks, rolled-off highlights), split toning, light desaturation, and **halation** (bright areas blurred and tinted warm, then blended back). |
| **Glow** | Highlight bloom: a soft brightness threshold, then a large blur, then a screen blend. A slight overall soften. |
| **Soft Skin** | Vision's person segmentation (`VNGeneratePersonSegmentationRequest`) intersected with a skin-tone mask. Edge-preserving smoothing is applied only inside that mask, so eyes, hair and the background stay sharp. |
| **Grain** | Metal kernel: animated in preview, seeded for stills. Stronger in midtones. Controls for amount and size. |

## Files (new repo at `C:\Users\amdha\Sites\cam18`)
- `project.yml`: XcodeGen spec (app target, unit-test target, camera and Photos usage descriptions in Info.plist).
- `Cam18/App/`: `Cam18App.swift`, `ContentView.swift`
- `Cam18/Camera/`:
  - `CameraSession.swift`: AVCaptureSession setup, lens switching, permissions
  - `PreviewRenderer.swift`: MTKView plus `CIContext`
  - `PhotoCapture.swift`
- `Cam18/Pipeline/`:
  - `StyleRecipe.swift`: Codable look plus all slider values, versioned
  - `StylePipeline.swift`: turns a recipe and an image into the output image
  - `FilmLook.swift`, `GlowLook.swift`, `SoftSkinLook.swift`, `Grain.swift`
  - `Kernels.metal`: grain, halation and blend kernels, built with the Core Image Metal flags
- `Cam18/Library/`:
  - `PhotoSaver.swift`: two save paths: editable (PHContentEditingOutput plus adjustment data) and baked (a plain `PHAssetCreationRequest` with the rendered HEIC)
  - `Settings.swift`: the `bakeInLook` preference (`@AppStorage`)
  - `EditorView.swift`: reopen a photo and change the recipe
- `Cam18/UI/`: look picker, Tone & Color pad, sliders
- `Cam18Tests/`:
  - recipe encode/decode
  - pipeline renders on bundled sample images, with output size and range checks
  - performance test of the preview path
- `.github/workflows/build.yml` (macOS runner):
  - install XcodeGen, generate the project
  - run tests on the simulator
  - build an **unsigned** `.ipa` with `CODE_SIGNING_ALLOWED=NO` and upload it as an artifact
  - upload test-rendered sample images as an artifact so the looks can be judged without a device

## Installing on the 17 Pro
1. Download the unsigned `.ipa` from the GitHub Actions run.
2. Sign and install it from Windows with **Sideloadly** or **AltStore**, using your own Apple ID. You enter the Apple ID yourself; I won't handle it.
3. On the phone, enable Developer Mode if asked. A free Apple ID's install expires after 7 days and has to be redone.

## What you need to provide
- A GitHub repository. A private one is fine; the macOS runner minutes come from your account.
- An Apple ID for sideloading.

## Verification
- **CI, on every push:**
  - the project generates, tests pass on the simulator, and the `.ipa` builds
  - the sample-render artifact shows each look at 0%, 50% and 100%
- **Simulator limit:** it has no camera, so the camera path isn't covered there. The editor and pipeline are.
- **On the 17 Pro (manual checklist):**
  - the preview runs smoothly with each look on all lenses
  - captured photos match the preview
  - with the toggle **off**, the original is kept: reopen the photo, change the look, then use Revert in Photos
  - with the toggle **on**, the saved photo shows the look when shared or opened elsewhere, Photos offers no Revert, and the toggle setting survives an app restart
  - Soft Skin leaves non-skin areas sharp

## Out of scope for v1
Video, RAW/ProRAW capture, a Photos-app editing extension, and App Store distribution.
