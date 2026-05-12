
# Starry Timelapse Airplane Remover (Star)

Star removes airplane and satellite trails from night-sky timelapse videos. It takes a sequence of still images, automatically detects and paints out bright transient streaks, and writes back a cleaned sequence ready to render into video.

## Example comparisons

### Northern Esmeralda County, Nevada

Original: https://vimeo.com/803304507  
Processed with Star: https://vimeo.com/803303679

### Smith Creek Valley, Nevada (with moonlight)

Original: https://vimeo.com/988073522  
Processed with Star: https://vimeo.com/950955396

---

## How it works

The key insight is that in a night-sky timelapse, the scene is nearly identical from frame to frame — stars rotate slowly, the foreground is fixed, and anything short-lived (an airplane, a satellite, a meteor) appears in only one or two frames before moving on.

Star exploits this by building a **clean reference image** for each frame: it takes several neighboring frames, aligns them so the stars overlap, and computes a per-pixel median that rejects the one-frame-only bright outliers. The original frame is then subtracted from this reference to reveal transients. Those bright differences are clustered into **blobs**, the blobs are run through a trained classifier to separate airplane trails from harmless bright stars, and the keepers are painted over with pixels from the clean reference.

In more detail:

1. **Horizon detection** — finds the skyline so that sky and ground regions can be treated separately.
2. **Frame alignment** — warps neighboring frames into the current frame's coordinate system using AKAZE/SIFT keypoints and a RANSAC homography. For static cameras, a second alignment pass covers the ground so that car headlights and low aircraft can also be removed.
3. **Clean reference stack** — sigma-clipped median of the aligned neighbors. Airplane pixels sit at the bright extreme of the sorted stack and are rejected before the median is computed. Stars appear in every frame at the same spot and are *not* outliers, so they survive.
4. **Outlier subtraction** — original minus reference, clipped to zero. What remains is a bright-on-black image of transient objects only.
5. **Blob finding** — connected-component flood fill with adaptive thresholds finds each candidate trail fragment. A Kernel Hough Transform pass reassembles fragments of the same trail into a single blob.
6. **Classification** — a trained decision-tree forest scores each blob. Features include size, brightness, linearity, position relative to the horizon, and whether a similar blob appears in neighboring frames.
7. **Pixel replacement** — blobs classified as airplanes are painted over with pixels from the clean reference, with a soft edge falloff so the seam is invisible.

---

## Two processing modes

**Automatic** — Star decides what to remove and writes the cleaned frames with no human involvement. A sub-option (`--clean-method automatic:true`) runs a second pass to restore single-frame events (meteors, bolides, fireworks) that the classifier would otherwise remove.

**Selective** — Star does the full detection and classification pipeline but waits for human confirmation. The GUI shows each frame with the classifier's suggested removals highlighted; the user approves or rejects each blob before anything is written. This is the right choice for cloudy nights, unusual events, or any sequence where you want fine-grained control.

---

## Static vs moving camera

**Static timelapse** (tripod, no pan) — Star builds a single global horizon mask and a smoothed homography for the whole sequence. It can align both sky *and* ground, so transients anywhere in the frame — car headlights, low-flying aircraft, objects near the horizon — are all candidates for removal.

**Moving timelapse** (pan, track, motion control) — The foreground shifts frame to frame, so Star can only align the sky. Anything bright *below* the horizon on a moving shot will not be subtracted and will pass through uncleaned. This is the largest known limitation of the current version.

---

## Applications

Star ships as two applications built on the same core processing library:

**`star` (CLI)** — runs any processing mode end-to-end from the terminal. Good for long unattended runs on large sequences. The `--detection-type` flag trades speed for thoroughness (`mild` through `excessive`). Run with `-w` to save per-frame blob data for later GUI review.

**Star.app (GUI)** — SwiftUI application for macOS. It can drive the full pipeline with a live progress view, let you scrub through frames, toggle individual blobs on or off, adjust parameters and re-run single stages, and mux the result back into a video. Selective mode is only fully usable in the GUI.

---

## What Star handles well and not well

**Works well:**
- Static cameras, clear or partly cloudy skies, normal overnight exposures
- Long sequences — the sigma-clipped median becomes more reliable as the frame count grows
- Sequences with mild camera drift (tripod settling, slight wind)
- Any sequence length from a few hundred to several thousand frames
- Stars are preserved by construction — they are never outliers

**Known limitations:**
- **Moving camera + ground transients** — headlights and low aircraft below the horizon on a moving shot are not removed
- **Fast-moving clouds** — cloud shapes change quickly enough that the median reference smears; use selective mode and manually skip cloudy frames
- **Dawn and dusk** — rapid global brightness changes generate many false positives in the subtraction step
- **Very short sequences (< ~5 frames)** — too few samples for reliable outlier rejection
- **Meteors** — a meteor looks identical to an airplane trail (one frame, bright streak) and will be removed in pure automatic mode; use `--clean-method automatic:true` or selective mode to restore them

---

## Typical workflow

1. Process your raw images in Lightroom / LRTimelapse / Topaz as you normally would, ending with a folder of 16-bit TIFF files.
2. Run `star -w <path-to-sequence>` to process the sequence automatically and save blob data alongside it.
3. Open the resulting config file in Star.app to review the output. Scrub through the video and fix any frames that look wrong.
4. Render the cleaned image sequence to video with ffmpeg or your preferred tool.

---

## Getting started

Download the latest release from the GitHub releases page:

https://github.com/brianm998/starry_timelapse_airplane_remover/releases

Two packages are available: the `star` command-line tool and the `Star.app` GUI. Either or both can be installed. The installer is self-contained — it bundles OpenCV and ffmpeg with no external dependencies required.

Star is under active development. For questions or bug reports, open an issue on GitHub.

---

## Technical details

For a full description of the processing pipeline — including the horizon detection algorithms, frame alignment math, sigma-clipping approach, blob refinement passes, and decision tree training process — see [PROCESSING_DESCRIPTION.md](PROCESSING_DESCRIPTION.md).
