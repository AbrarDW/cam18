# Cam18

A film-style camera app for iPhone 17 Pro (iOS 26 or later). It has five looks: **Tone & Color**, **Film**, **Glow**, **Soft Skin** and **Grain**. Each has its own intensity slider, and you can stack them. Cam18 is an original take on these effects, built only on public Apple frameworks: AVFoundation, Core Image with custom Metal kernels, Vision and PhotoKit. It doesn't modify the system in any way. See [PLAN.md](PLAN.md) for the design.

## How it works

- **One pipeline.** `StylePipeline` renders both the live preview, at screen resolution, and full-resolution stills. Every blur radius and grain size scales with image size, so the photo matches what you saw. A unit test checks this.
- **Bake in look** (toggle at the top of the viewfinder, off by default, remembered between launches). The badge shows which mode the next photo will use:
  - **EDITABLE** (off): the untouched original is saved with the look applied as an edit. The JSON recipe is stored as `PHAdjustmentData`. Opening the photo again from the library button lets you change or remove the look, and **Revert** in Photos restores the original.
  - **BAKED** (on): a plain rendered HEIC is saved. It keeps the camera EXIF and adds the look name to the EXIF user comment. No original is kept.

## Layout

```
project.yml              XcodeGen spec (the .xcodeproj is generated, not committed)
Cam18/App                App entry and main screen
Cam18/Camera             AVCaptureSession, live preview renderer, photo capture
Cam18/Pipeline           Recipe, pipeline, the looks, Metal kernels, Vision segmentation
Cam18/Library            PhotoKit saving (editable / baked), editor, settings
Cam18/UI                 Look picker, Tone & Color pad, sliders, badge, shutter
Cam18Tests               Recipe, pipeline, metadata and performance tests + sample images
.github/workflows        macOS CI: generate, test on simulator, build unsigned .ipa
```

## Getting the app (no Mac needed)

1. Push to GitHub, or open the **Actions** tab and run **Build** manually.
2. Open the finished run and download:
   - **Cam18-unsigned-ipa**: the app.
   - **sample-renders**: each look at 0%, 50% and 100% on the bundled sample images, plus a contact sheet per sample, so you can judge the looks without a device.
3. On Windows, install the `.ipa` with **Sideloadly** or **AltStore**. Sign in with your own Apple ID inside that tool. Cam18 never asks for or handles your Apple ID.
4. On the iPhone, enable **Developer Mode** if asked (Settings › Privacy & Security). With a free Apple ID the install expires after 7 days; reinstall it the same way.

## Building on a Mac (optional)

```sh
brew install xcodegen
xcodegen generate
open Cam18.xcodeproj
```

## On-device checklist

The simulator has no camera, so check these on the 17 Pro:

- [x] The preview runs smoothly with each look on every lens.
- [x] Captured photos match the preview.
- [x] Toggle **off**: reopen the photo in Cam18 and change the look, then use Revert in Photos.
- [x] Toggle **on**: the photo shows the look when shared, Photos offers no Revert, and the toggle survives an app restart.
- [x] Soft Skin leaves non-skin areas sharp.

## Out of scope for v1

Video, RAW/ProRAW capture, a Photos editing extension, and App Store distribution.
