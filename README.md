
# Starry Timelapse Airplane Remover (Star)

![Star, the robot on a rock with a laptop under a calm night sky](docs/readme-hero.jpg)

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

Star exploits this by building a **clean reference image** for each frame: it takes several neighboring frames, aligns them so the stars overlap, and computes a per-pixel median that rejects the one-frame-only bright outliers. The ground is aligned and merged the same way, and the two halves are joined along the horizon. In **Automatic** mode that composite *is* the output frame — every airplane, satellite, car light and meteor is gone, with no per-blob decisions at all.

The selective modes add a second stage on top: the original frame is compared against the clean reference, the bright differences are clustered into **blobs**, and a trained classifier decides which blobs to remove (Selective) or which to bring back (Automatic with preservation).

The steps every mode runs:

1. **Horizon detection** — finds the skyline so that sky and ground can be aligned separately. A static sequence finds it once, from a median of frames spread across the whole sequence; a moving sequence detects it per frame and then reconciles every frame's line along the ground alignment.
2. **Star alignment** — warps neighboring frames into the current frame's coordinate system using AKAZE/SIFT keypoints on the sky and a RANSAC homography.
3. **Earth alignment** — on a static camera the ground needs no warp and is merged directly. On a moving camera the ground is aligned as the camera turning about its own centre, with the lens focal length worked out from the frames themselves; a neighbor whose ground cannot be tracked is dropped from the merge rather than smearing it.
4. **Clean reference stack** — sigma-clipped median of the aligned neighbors. Airplane pixels sit at the bright extreme of the sorted stack and are rejected before the median is computed. Stars appear in every frame at the same spot and are *not* outliers, so they survive.
5. **Composite** — the star-aligned merge above the horizon, the earth-aligned merge below it. This is the Automatic output.

The extra steps the selective modes run (Selective, and Automatic with "Selective Auto Clean"):

6. **Outlier subtraction** — original minus the clean reference, clipped to zero. What remains is a bright-on-black image of transient objects only.
7. **Blob finding** — connected-component flood fill with adaptive thresholds finds each candidate trail fragment. A Kernel Hough Transform pass reassembles fragments of the same trail into a single blob.
8. **Classification** — a trained decision-tree forest scores each blob. Features include size, brightness, linearity, position relative to the horizon, and whether a similar blob appears in neighboring frames.
9. **Pixel replacement** — in Selective, blobs classified as airplanes are painted over the original with pixels from the composite; in Automatic with preservation, blobs classified as worth keeping are copied back from the original onto the composite. Either way with a soft edge falloff so the seam is invisible.

---

## Processing modes

**Automatic** (the default) — every frame is replaced by its clean composite: the median-merged sky above the horizon and the median-merged ground below it. No blobs are found or classified, so there is nothing to review per frame. Everything that moved is removed, meteors included. Clouds come out a little smoother than in the original, since they are median-merged too.

**Automatic with Selective Auto Clean** (`--clean-method automatic:true`) — the Automatic output, plus the blob stage run in reverse: blobs the classifier decides are worth keeping (meteors, bolides, fireworks) are copied back from the original frame. The classifier cannot yet reliably tell meteors from airplanes and satellites, so check the frames.

**Selective** — starts from the original frame and replaces only the blobs classified as airplanes or satellites, using pixels from the composite. Everything else, clouds included, is left exactly as shot. The GUI shows each frame with the classifier's choices highlighted and lets you flip any of them. This is the right choice for cloudy nights, unusual events, or any sequence where you want fine-grained control.

**Dirty** — the opposite of cleaning: each pixel becomes the original minus the clean reference, so everything that stayed still goes black and only what moved keeps its colour. Useful for seeing exactly what Star would remove.

---

## Static vs moving camera

**Static timelapse** (tripod, no pan) — Star finds one horizon for the whole sequence and applies one smoothed sky homography throughout. The ground does not move, so it is median-merged without any warp, and transients anywhere in the frame — car headlights, low-flying aircraft, objects near the horizon — are removed.

**Moving timelapse** (pan, track, motion control; `--moving-camera`) — sky and ground are aligned separately, each with its own homography per neighbor, so ground transients are removed here too. The ground is modelled as a camera rotation, which keeps the edges of a wide-angle pan from smearing, and every frame's horizon is reconciled against the rest of the sequence so it does not flicker. A foreground with no trackable detail — very dark, or clipped to black before it reached Star — cannot be aligned; those neighbors drop out of the ground merge, the ground falls back to the frame's own pixels, and Star warns that it could not track it. Earth alignment can be switched off in settings.

---

## Applications

Star ships as a command-line tool and graphical clients, all built on the same core processing library:

**`star` (CLI)** — runs any processing mode end-to-end from the terminal. Good for long unattended runs on large sequences. `--render-video` renders the result to a video when the run finishes. For the selective modes, `--detection-type` trades speed for thoroughness in blob finding (`mild` through `excessive`) and `-w` saves per-frame blob data for later GUI review; neither does anything in plain Automatic, which finds no blobs.

**Star.app (macOS) and Star Desktop (Windows, Linux)** — the graphical clients, a native SwiftUI app and a Kotlin/Compose app over the same core. They drive the full pipeline with a live progress view, let you scrub through frames, toggle individual blobs on or off, adjust parameters and re-run single stages, and render the result back into a video. Reviewing selective-mode blobs needs a graphical client.

---

## What Star handles well and not well

**Works well:**
- Static cameras, clear or partly cloudy skies, normal overnight exposures
- Moving cameras (pans, sliders, motion control) whose foreground has visible detail — sky and ground are both cleaned
- Long sequences — the sigma-clipped median becomes more reliable as the frame count grows
- Sequences with mild camera drift (tripod settling, slight wind)
- Any sequence length from a few hundred to several thousand frames
- Stars are preserved by construction — they are never outliers

**Known limitations:**
- **Untrackable ground on a moving shot** — a foreground that is black or featureless cannot be aligned, so ground transients there pass through; keep shadow detail in the exported frames
- **Fast-moving clouds** — cloud shapes change quickly enough that the median reference smears; try `--cloud-aware-merge`, or use selective mode so cloudy frames keep their original pixels
- **Dawn and dusk** — rapid global brightness changes make alignment harder and generate many false positives in the selective modes' blob stage
- **Very short sequences (< ~5 frames)** — too few samples for reliable outlier rejection
- **Meteors** — a meteor is a moving bright streak like any other, so Automatic removes it; use `--clean-method automatic:true` or selective mode to keep them

---

## Typical workflow

1. Process your raw images in Lightroom / LRTimelapse / Topaz as you normally would, ending with a folder of 16-bit TIFF files.
2. Run `star <path-to-sequence>` (add `--moving-camera` for a pan or slider shot) to process it automatically, or open the folder in Star.app / Star Desktop and press Process.
3. Open the resulting config file in a graphical client to review the output. Scrub through the video and fix any frames that look wrong — for example by switching a cloudy stretch to selective.
4. Render the cleaned image sequence to video from the graphical client, with `star --render-video`, or with ffmpeg or your preferred tool.

---

## Getting started

Go to the [download page](https://brianm998.github.io/starry_timelapse_airplane_remover/). It detects your platform and gives you the right installer. (All versions are also on the [GitHub releases page](https://github.com/brianm998/starry_timelapse_airplane_remover/releases).)

Available:

- **macOS:** `Star.app` (the native GUI) and the `star` command-line tool.
- **Windows and Linux:** Star Desktop (the graphical client) and the `star` command-line tool.

A video can be opened directly (the GUI and `star` both take one): its frames are extracted to images first, and with "Extract video in background" (`--extract-in-background`; on by default for ProRes and other intra-only formats) processing starts while they are still being extracted. See `plans/STREAMING_FRAME_INTAKE_PLAN.md`.

Either or both can be installed. The installers are self-contained — they bundle OpenCV and ffmpeg (native on Apple silicon and Intel, with VideoToolbox hardware encoding on a Mac) with no external dependencies required. The `star` command-line tool needs ffmpeg only for video input and `--render-video`; it uses `$STAR_FFMPEG_DIR` if set, otherwise a copy beside itself, otherwise one on `PATH`. See [ffmpeg/README.md](ffmpeg/README.md) for how ffmpeg is built.

Star is under active development. For questions or bug reports, open an issue on GitHub.

---

## Technical details

For a full description of the processing pipeline — including the horizon detection algorithms, sky and ground alignment, sigma-clipping approach, the selective modes' blob refinement passes, and decision tree training process — see [PROCESSING_DESCRIPTION.md](PROCESSING_DESCRIPTION.md).
