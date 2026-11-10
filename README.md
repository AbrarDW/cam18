# Cam18

A film-style camera app for iPhone 17 Pro (iOS 26 or later). Pick a **colour style**, fine-tune it with the **Tone & Color** pad and the **Adjust** sliders, then stack **Film**, **Glow**, **Soft Skin** and **Grain** on top. Choose the photo's **aspect ratio**, and save any combination as a **preset** for one-tap use next time. Cam18 is an original take on these effects, built only on public Apple frameworks: AVFoundation, Core Image with custom Metal kernels, Vision and PhotoKit. It doesn't modify the system in any way. See [PLAN.md](PLAN.md) for the original design.

## What you can set

- **Style** (12 colour styles): Standard, Warm Gold, Amber, Rose, Cool Blue, Teal & Orange, Vivid, Faded, Moody, Pastel, Mono and Mono Contrast. Each has an intensity slider and remembers the value you last used. The Tone & Color pad sits in the same section.
- **Adjust**: Exposure, Contrast, Highlights, Shadows, Fade, Saturation, Warmth, Tint, Vignette and Sharpness. Each runs from −100 to +100; double-tap a name to reset it.
- **Looks**: Film, Glow, Soft Skin and Grain, each with its own intensity.
- **RAW** (top bar, on by default): photos are captured as RAW sensor data, with none of Apple's noise reduction, sharpening, tone mapping or multi-frame merging, and developed by Cam18. Switch it off to use the camera's processed photo instead. The button is struck through on a lens that has no RAW; that lens then uses the processed photo.
- **Aspect ratio** (top bar): 4:3, 16:9, 3:2 or 1:1. It follows how you hold the phone, so 16:9 becomes 9:16 in portrait.
- **Presets** (strip above the shutter): tap **Save** to store the current style, looks, adjustments and aspect ratio under a name. Tap a preset to apply it; touch and hold to update, rename or delete it.
- The app reopens with the settings, lens and section you used last.

## How it works

- **One pipeline.** `StylePipeline` renders both the live preview, at screen resolution, and full-resolution stills. Every blur radius and grain size scales with image size, so the photo matches what you saw. A unit test checks this.
- **Colour styles are lookup tables** (LUTs) generated in code from a few numbers per style (`ColorStyle.swift`), so there are no LUT files to ship and adding a style is a few lines.
- **RAW capture.** With RAW on, the camera delivers a Bayer RAW DNG (not Apple ProRAW, which is already processed). `StillRenderer.develop` turns it into a picture with luminance noise reduction and local tone mapping at zero, the decoder's own capture sharpening, and only light colour-noise cleanup; the looks are applied to that. RAW is captured at the sensor's largest size (48 MP on the 17 Pro) and developed at about 24 MP. In editable mode the DNG is the original that is kept. The live preview still comes from the camera's video feed, which the phone processes, so a RAW photo can differ a little from the viewfinder in brightness, colour and noise. A 48 MP DNG is large, roughly 50 to 90 MB per photo.
- **The crop is part of the recipe**, not cut from the file. In editable mode the full 4:3 original is kept, so the shape can be changed later in the editor and **Revert** in Photos brings back the whole frame. The crop runs before the looks in both preview and photo.
- **Bake in look** (the badge at the top left; tap it to switch, off by default, remembered between launches). The badge shows which mode the next photo will use:
  - **EDITABLE** (off): the untouched original is saved with the look applied as an edit. The JSON recipe is stored as `PHAdjustmentData`. Opening the photo again from the library button lets you change or remove the look, and **Revert** in Photos restores the original.
  - **BAKED** (on): a plain rendered HEIC is saved, already cropped. It keeps the camera EXIF and adds the look name to the EXIF user comment. No original is kept.

## Layout

```
project.yml              XcodeGen spec (the .xcodeproj is generated, not committed)
Cam18/App                App entry and main screen
Cam18/Camera             AVCaptureSession, live preview renderer, photo capture
Cam18/Pipeline           Recipe, pipeline, colour styles, adjustments, crop, the looks,
                         Metal kernels, Vision segmentation
Cam18/Library            PhotoKit saving (editable / baked), editor, settings, presets
Cam18/UI                 Section picker, style strip, pad, sliders, presets, badge, shutter
Cam18Tests               Recipe, pipeline, preset, metadata, performance and screenshot
                         tests + sample images
.github/workflows        macOS CI: generate, test on simulator, build unsigned .ipa
```

## Getting the app (no Mac needed)

1. Push to GitHub, or open the **Actions** tab and run **Build** manually.
2. Open the finished run and download:
   - **Cam18-unsigned-ipa**: the app.
   - **sample-renders**: each look at 0%, 50% and 100%, every colour style, every adjustment at −100 and +100, and each aspect ratio on the bundled sample images, with contact sheets, so you can judge them without a device. The `ui-*.png` files are screenshots of the camera screen.
3. On Windows, install the `.ipa` with **Sideloadly** or **AltStore**. Sign in with your own Apple ID inside that tool. Cam18 never asks for or handles your Apple ID.
4. On the iPhone, enable **Developer Mode** if asked (Settings › Privacy & Security). With a free Apple ID the install expires after 7 days; reinstall it the same way.

## Building on a Mac (optional)

```sh
brew install xcodegen
xcodegen generate
open Cam18.xcodeproj
```

## On-device checklist

The simulator has no camera, so check these on the 17 Pro.

Version 1 (all passed):

- [x] The preview runs smoothly with each look on every lens.
- [x] Captured photos match the preview.
- [x] Toggle **off**: reopen the photo in Cam18 and change the look, then use Revert in Photos.
- [x] Toggle **on**: the photo shows the look when shared, Photos offers no Revert, and the toggle survives an app restart.
- [x] Soft Skin leaves non-skin areas sharp.

Styles, Adjust, aspect ratio, presets and the new UI (not yet checked):

- [ ] RAW on: photos save from every rear lens, upright and sideways, and look right in Photos (editable and baked).
- [ ] RAW on: reopen a RAW photo in Cam18, change the look and save.
- [ ] RAW on vs off: compare the same scene; RAW should show more grain and less sharpening.
- [ ] Each aspect ratio: the saved photo has the framing the viewfinder showed, held upright and sideways.
- [ ] Editable mode: reopen a cropped photo and change its aspect ratio; Revert in Photos restores the full 4:3 frame.
- [ ] Each colour style and Adjust slider looks the same in the saved photo as in the preview.
- [ ] The preview stays smooth with a style, several adjustments and looks stacked.
- [ ] A saved preset is still there, and applies correctly, after restarting the app.
- [ ] The app reopens with the last settings, aspect ratio and lens.
- [ ] The glass controls stay readable over bright and dark scenes.

## Out of scope for v1

Video, Apple ProRAW, a Photos editing extension, and App Store distribution.
