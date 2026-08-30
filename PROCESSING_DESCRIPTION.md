# How `star` Processes an Image Sequence

`star` (the Nighttime Timelapse Airplane Remover) takes a sequence of long-exposure
night-sky frames and produces a corresponding sequence with airplane and satellite
trails (and most other transient bright streaks) removed. This document describes
how it does that, working from a high-level overview down to the specific
algorithms used.

---

## 1. High-Level Description

A timelapse of the night sky shot from a tripod is, frame to frame, *almost* the
same picture: the stars rotate slowly, the foreground is fixed, and any
short-lived bright thing — an airplane, a satellite, a meteor — appears in only
one or two frames before moving on. `star` exploits exactly this redundancy.

For each frame it builds a **clean reference image** by stacking several
neighboring frames and taking a per-pixel median that throws out the brightest
outliers. The original frame is then compared against that reference; whatever
is far brighter than the reference is a candidate for removal. Candidates are
clustered into **blobs**, the blobs are classified, and the airplane-shaped ones
are painted over with pixels from the clean reference.

The two top-level modes are:

- **Automatic** — `star` decides what to remove and writes out the cleaned
  frames with no human in the loop. It also has a sub-option ("selective auto
  preservation") that runs the selective pipeline a second time *in reverse*,
  reaching back into the original frame to restore objects worth keeping
  (meteors, bright bolides, fireworks) on top of the otherwise-cleaned output.
- **Selective** — `star` does the full detection pipeline but does not act on
  it. The user opens the GUI, reviews each frame, and approves or rejects the
  decision tree's verdict on each blob. This mode is meant for cloudy nights,
  ambiguous events, or anything where you want fine-grained control. The CLI
  can produce the classifier output for selective mode, but the validation step
  itself happens only in the GUI.

`star` adapts to two very different shooting situations:

- **Static timelapse** — camera doesn't move. `star` can earth-align as well
  as star-align, build a clean composite of the *ground* in addition to the
  sky, and remove any transient bright thing anywhere in the frame, including
  car headlights and low-flying objects near the horizon.
- **Moving timelapse** — panned, tracked, or motion-controlled. The ground is
  moving frame to frame, so `star` cannot yet build a clean median of the
  earth half of the frame. It can only star-align the sky. As a consequence,
  any bright transient *below the horizon line* — car headlights, low aircraft,
  a passing flashlight — will not be cleanly subtracted away and may slip
  through. This is the largest known limitation of `star` today.

---

## 2. Technical Pipeline Breakdown

The pipeline is built as a dependency graph of `OperationQueue` operations
constructed in
[`FrameGraphBuilder.build()`](StarCore/Sources/StarCore/FrameGraphBuilder.swift:119).
Each frame becomes a chain of operations, and the chains are stitched together
where neighboring frames share work (notably horizon merging and homography
validation). The graph is roughly:

```
  per frame:
    ┌────────────────────┐
    │ Horizon Detection  │   ← detects the skyline
    └─────────┬──────────┘
              ▼
    ┌────────────────────┐
    │ Horizon Merge      │   ← combines neighbor horizons
    └─────────┬──────────┘     into one robust estimate
              ▼
    ┌────────────────────┐
    │ Keypoint Extract   │   ← finds matchable features
    └─────────┬──────────┘     in sky and (if static) earth
              ▼
    ┌────────────────────┐
    │ Homography Compute │   ← warps neighbor frames into
    └─────────┬──────────┘     this frame's coordinate system
              ▼
    ┌────────────────────┐
    │ Alignment Validate │   ← rejects bad warps, smooths
    └─────────┬──────────┘     the homography over time
              ▼
    ┌────────────────────┐
    │ Outlier Detection  │   ← clean-reference subtraction
    └─────────┬──────────┘     and blob finding
              ▼
    ┌────────────────────┐
    │ Final Merge        │   ← classify, replace pixels,
    └────────────────────┘     write out the cleaned frame
```

The orchestrator is
[`ImageSequenceProcessor`](StarCore/Sources/StarCore/ImageSequenceProcessor.swift)
which iterates the input sequence and feeds the graph. The per-frame work
runs inside
[`FrameAirplaneRemover`](StarCore/Sources/StarCore/FrameAirplaneRemover.swift),
which is the largest single file in the project and the central place to look
when tracing what happens to one frame.

### 2.1. Static vs Moving — How the Graph Differs

The graph builder branches on whether the user has declared the timelapse to
be moving (`--moving-camera` on the CLI):

- **Static**: a single horizon-merge operation depends on *every* per-frame
  horizon detection
  ([`FrameGraphBuilder.swift:292`](StarCore/Sources/StarCore/FrameGraphBuilder.swift:292)),
  producing one global horizon mask. Homography validation then finds the
  median homography across the whole sequence and applies it uniformly
  ([`AlignmentValidationOp.swift:46`](StarCore/Sources/StarCore/AlignmentValidationOp.swift:46)).
  Earth alignment is available, so the clean reference is built from
  neighbor frames in *both* sky and ground regions.
- **Moving**: each frame's horizon merge depends only on its local neighbors
  ([`FrameGraphBuilder.swift:261`](StarCore/Sources/StarCore/FrameGraphBuilder.swift:261)).
  Homography is per-frame with no global smoothing. Earth alignment is on by
  default here too, so the ground portion of the clean reference is built from
  neighbor frames as well — except where the ground cannot be tracked
  confidently, in which case that neighbor drops out and the ground falls back
  to the original frame, subtracting to zero and letting ground-level outliers
  through untouched.

### 2.2. Automatic vs Selective in Code

The clean mode is a single enum
([`CleanMethod.swift:9`](StarCore/Sources/StarCore/CleanMethod.swift:9)):

```swift
public enum CleanMethod {
    case automatic(Bool)   // Bool = "also run selective preservation in reverse"
    case selective
}
```

Both branches run the *same* outlier-detection pipeline. The difference is
only what happens after blobs are classified:

- `.automatic(false)`: cleaned frame is written directly.
- `.automatic(true)`: cleaned frame is written, then the selective pipeline
  runs in reverse to bring meteors and other "bright but worth keeping"
  events back from the original.
- `.selective`: detection runs and a classifier verdict is attached to every
  blob, but no pixels are replaced until the user opens the frame in the
  GUI and confirms. Even in `.selective` mode the GUI starts with the
  decision tree's pre-classification — the user is reviewing the tree's
  selections, not picking blobs from scratch.

The CLI accepts `--clean-method selective` and will produce the classification
data, but the actual "remove these, keep those" decisions need the GUI.

---

## 3. Low-Level Technical Detail

This section describes how each stage actually works.

### 3.1. Horizon Detection

Horizon detection produces a binary mask the same size as the input image,
where white = sky and black = ground. (The convention is enforced everywhere
in the codebase; see e.g.
[`HorizonAccumulator.swift`](StarCore/Sources/StarCore/HorizonAccumulator.swift).)

`star` runs several methods in parallel and then ranks the results.

- **Otsu thresholding + Canny edges**
  ([`FrameAirplaneRemover.swift:2859`](StarCore/Sources/StarCore/FrameAirplaneRemover.swift:2859)).
  Otsu's method finds the histogram split between dark (ground) and bright
  (sky) pixels by maximizing inter-class variance.<sup>[Otsu 1979]</sup>
  Canny edge detection<sup>[Canny 1986]</sup> is run with several
  parameter combinations, including with and without the L2 gradient norm.
- **Dynamic-programming horizon**
  ([`FrameAirplaneRemover.swift:2705`](StarCore/Sources/StarCore/FrameAirplaneRemover.swift:2705)).
  The horizon is modelled as the lowest-cost path across the image, where
  per-column cost combines a Sobel-gradient term, a Canny-edge term, and a
  smoothness penalty (`smoothnessLambda`) that punishes large vertical jumps
  between adjacent columns. A grid search over the parameter space picks
  the best result, which is upscaled back to full resolution.
- **Random-walker / SIOX-style segmentation**
  ([`StarCpp/.../RandomWalkerHorizon.cpp`](StarCpp/Sources/StarCpp/RandomWalkerHorizon.cpp))
  is run as one of the candidate methods and median-combined with the
  others.

Each candidate horizon is scored by
[`AdaptiveHorizonDetector`](StarCore/Sources/StarCore/AdaptiveHorizonDetector.swift:6):

- `smoothnessScore` — penalizes high derivative variance (real horizons
  change gradually).
- `edgeAlignmentScore` — rewards alignment with the Canny edge map.
- `coverageScore` — rejects degenerate "all sky" or "all ground" masks.
- `localConsistencyScore` — penalizes single-pixel spikes.
- `cropBoundaryScore` — multiplier that suppresses flat lines pinned to a
  crop edge (a common failure mode).

For static timelapses the per-frame horizons are then accumulated across
*all* frames as a `CV_32S` per-pixel vote count
([`HorizonAccumulator.swift:39`](StarCore/Sources/StarCore/HorizonAccumulator.swift:39))
and finalized by majority vote. This eliminates per-frame jitter caused
by airplane lights or moving clouds biasing the segmentation.

### 3.2. Frame-to-Frame Alignment

Alignment is the step that makes a per-pixel median possible. `star`
delegates it to OpenCV via the `StarCpp` C++ bridge in
[`ImageAligner.cpp`](StarCpp/Sources/StarCpp/ImageAligner.cpp).

The process per neighbor pair is:

1. Detect keypoints and descriptors with **AKAZE**<sup>[Alcantarilla
   2013]</sup>
   ([`ImageAligner.cpp:447`](StarCpp/Sources/StarCpp/ImageAligner.cpp:447))
   and **SIFT**<sup>[Lowe 2004]</sup>
   ([`ImageAligner.cpp:451`](StarCpp/Sources/StarCpp/ImageAligner.cpp:451)),
   capped by `maxKeypoints`. Two detectors are used because they have
   different failure modes — AKAZE handles low-contrast sky better, SIFT is
   more robust to scale changes.
2. Match descriptors. Brute-force `cv::BFMatcher` with `NORM_L2`
   ([`ImageAligner.cpp:514`](StarCpp/Sources/StarCpp/ImageAligner.cpp:514))
   for SIFT, falling back to `cv::FlannBasedMatcher`
   ([`ImageAligner.cpp:547`](StarCpp/Sources/StarCpp/ImageAligner.cpp:547))
   for the AKAZE pass. Lowe's ratio test filters out ambiguous matches.
3. Compute a homography with `cv::findHomography(..., cv::RANSAC, 10)`
   ([`ImageAligner.cpp:564`](StarCpp/Sources/StarCpp/ImageAligner.cpp:564))
   — RANSAC<sup>[Fischler & Bolles 1981]</sup> with a 10-pixel
   reprojection threshold rejects mismatched keypoints (which matters a
   lot when your scene is mostly noise and stars).
4. Apply the homography with `cv::warpPerspective`
   ([`ImageAligner.cpp:620`](StarCpp/Sources/StarCpp/ImageAligner.cpp:620)).

The keypoint extraction is done **twice** when earth alignment is possible:
once on the sky region (using the horizon mask to reject ground keypoints,
which would otherwise pollute the sky alignment with un-rotated foreground)
and once on the ground region. The two homographies are stored separately;
the final clean reference can use the sky homography above the horizon and
the earth homography below it.

`AlignmentValidationOp`
([`AlignmentValidationOp.swift:8`](StarCore/Sources/StarCore/AlignmentValidationOp.swift:8))
then sanity-checks the result. For static sequences it computes the
median homography across the whole sequence and rejects any frame whose
homography deviates too far. For moving sequences it can only smooth
locally, which is part of why moving sequences are harder.

### 3.3. The Clean Reference: Sigma-Clipped Median Stack

This is the single most important step. For each frame `F`, `star`
gathers `N` neighboring frames warped into `F`'s coordinate system and
builds a per-pixel "what *should* this pixel look like" image via a
**sigma-clipped median** in
[`ImageAligner.cpp:73`](StarCpp/Sources/StarCpp/ImageAligner.cpp:73):

```
for each pixel (x,y), each channel:
    collect values v_0 … v_{N-1} from the N aligned frames
    sort them
    compute mean μ and standard deviation σ of the sorted values
    threshold T = μ + k·σ
    discard any value above T (these are the airplane/satellite hits)
    output = median of the remaining values
```

This is the standard "kappa-sigma clipping" used in astrophotographic
stacking.<sup>[Howell 2006, *Handbook of CCD Astronomy*]</sup> The
intuition: airplane and satellite trails appear in only one frame at a
given (x,y) and they make that frame *brighter* than the others, so they
sit at the top of the sorted list and are rejected. A pure plain median
would also reject them, but the sigma clip handles the case where two
neighboring frames happen to catch the same trail (sigma-clip rejects
both; a plain median would split them and bias the result upward).

When earth alignment is available, two such stacks are built — one from
sky-aligned warps, one from earth-aligned warps — and combined using the
horizon mask in
[`FrameAirplaneRemover.swift:5823`](StarCore/Sources/StarCore/FrameAirplaneRemover.swift:5823)
via `PixelatedImage.apply()`. When earth alignment is *not* available —
switched off, or every ground homography rejected for want of RANSAC
consensus — the ground portion of the reference is just the original
frame's ground, which by construction subtracts to zero, and that is
precisely why ground transients leak through.

### 3.4. Outlier Subtraction

The original frame minus the clean reference is computed in
[`PixelatedImageBridge.cpp:335`](StarCpp/Sources/StarCpp/PixelatedImageBridge.cpp:335):

```cpp
cv::subtract(originalGray, referenceGray, diff);
cv::max(diff, 0, diffClipped);   // clip negatives to zero
```

Both inputs are converted to the same depth and made grayscale first.
Negative differences (the original is *darker* than the reference) are
clipped to zero. The resulting "subtraction image" is bright wherever
the original frame has something the median composite did not — by
definition, transient bright objects.

### 3.5. Blob Finding

The subtraction image is fed into `BlobFinder`
([`BlobFinder.swift:19`](StarCore/Sources/StarCore/BlobFinder.swift:19)),
which does flood-fill connected-component analysis with adaptive
brightness thresholds (`minPixelIntensity`, `startMinContrast`,
`endMinContrast`). Each connected region becomes a `Blob`
([`Blob.swift:20`](StarCore/Sources/StarCore/Blob.swift:20)) holding
its pixel set, bounding box, and per-pixel brightness deltas relative
to the reference.

The detection level — `mild`, `strong`, `stronger`, `excessive`
([`DetectionType.swift:19`](StarCore/Sources/StarCore/DetectionType.swift:19))
— controls how aggressive the thresholds are. `mild` is 2-4× faster but
will miss the dimmest trails; `excessive` finds far more candidates at
the cost of much longer runtime and many more false positives that the
classifier then has to throw out.

After the initial blob set is found, several refinement passes run:

- **Linear blob extension/connection** uses the **Kernel Hough
  Transform**<sup>[Fernandes & Oliveira 2008]</sup> via the `KHTSwift`
  package
  ([`LinearBlobConnector.swift:50`](StarCore/Sources/StarCore/LinearBlobConnector.swift:50),
  [`HoughLineFinder.swift:119`](StarCore/Sources/StarCore/HoughLineFinder.swift:119))
  to find collinear blob fragments and merge them into a single trail.
  Airplane trails are usually broken into pieces by the brightness
  threshold; KHT is what reassembles them.
- **Small-blob removal** discards specks too small to be plausible
  trails.
- **Border-brightness removal** discards blobs hugging the image edge
  (often vignetting artifacts).

### 3.6. Decision Tree Classification

Each blob is wrapped in an `OutlierGroup`
([`OutlierGroup.swift:45`](StarCore/Sources/StarCore/OutlierGroup.swift:45))
and fed to a decision tree classifier
([`SwiftDecisionTree.swift`](StarCore/Sources/StarCore/SwiftDecisionTree.swift),
[`OutlierGroupClassifier.swift`](StarCore/Sources/StarCore/OutlierGroupClassifier.swift)).
Features used include:

- Size (pixel count) and bounding-box aspect ratio.
- Mean and peak brightness above the local reference.
- Linearity score from the KHT line fit (`lineIntensityScore`,
  `linePixelScore`).
- Position relative to the horizon.
- Whether a similar blob exists in neighboring frames (truly stationary
  objects like stars are filtered out earlier; airplane trails are
  short-lived but a meteor lasts only one frame, which is part of how
  meteors get distinguished from satellites).

The trees themselves live in `StarDecisionTrees/` as a separately
compiled static library — this is generated source code produced by
[`decision_tree_generator/`](decision_tree_generator/) from a
hand-validated training set. Generating new trees is a separate offline
process and ships as part of `star` as compiled `.a` libraries (one
per platform).

In **automatic** mode the classifier's "this is a plane" verdict
triggers removal directly. In **selective** mode the verdict is only a
suggestion; the GUI shows it to the user and the user accepts or
rejects each one.

### 3.7. Pixel Replacement

For blobs marked for removal, pixels are replaced by interpolating
from the clean reference, with a soft alpha falloff at the blob's
edge so the seam isn't visible. The mask is built in
[`RemoveMask.swift:24`](StarCore/Sources/StarCore/RemoveMask.swift:24)
as a circular gradient — fully opaque inside, fading linearly to
transparent across a configurable distance — and applied in
[`FrameAirplaneRemover.removeAirplanes()`](StarCore/Sources/StarCore/FrameAirplaneRemover.swift:4836).
Near the horizon the blend is biased toward the earth-aligned
reference (within ~60 pixels of the horizon line) so trails that
straddle the skyline don't pull foreground colors into the sky or
vice versa.

### 3.8. Output

Cleaned frames are written by `FrameSaveQueue` and then optionally
muxed back into a video using the bundled `ffmpeg` via
[`FFmpegCodec.swift`](StarCore/Sources/StarCore/FFmpegCodec.swift) /
[`FFmpegMuxer.swift`](StarCore/Sources/StarCore/FFmpegMuxer.swift).

---

## 4. CLI vs GUI

### CLI (`star`)

Located in [`cli/Sources/star/`](cli/Sources/star/). Defined as an
`AsyncParsableCommand`. Notable options
([`StarCli.swift`](cli/Sources/star/StarCli.swift)):

| Flag | Purpose |
|---|---|
| `-c` / `--clean-method` | `automatic`, `automatic:true`, `automatic:false`, or `selective` |
| `--moving-camera` | Disable global homography smoothing and earth alignment |
| `--no-horizon` | Skip horizon detection entirely |
| `-d` / `--detection-type` | `mild`, `strong`, `stronger`, `excessive` |
| `-o` / `--output-path` | Where to write the cleaned frames |
| `-w` / `--write-outlier-group-files` | Persist blob data for later GUI review |
| `-W` / `--write-outlier-classification-values` | Persist classifier feature data for tree training |
| `-L` / `--last-frame` | Stop early at frame N |

The CLI can run any mode end-to-end, including selective. What it
*cannot* do is run the human-validation step inside selective: when run
with `--clean-method selective`, it produces the outlier files but does
not produce a final cleaned video — the user has to open the project in
the GUI to confirm selections and trigger the actual replacement.

### GUI (`star.app`)

SwiftUI app in [`gui/star/`](gui/star/). It can:

- Drive the full pipeline, with live progress per frame.
- Render any frame at any stage of the pipeline (original, subtraction
  image, blob overlay, classifier verdict, final).
- Show the per-blob classifier output and let the user toggle individual
  blobs on/off — this is the validation step that selective mode needs.
- Let the user adjust horizon, alignment, and detection parameters and
  re-run individual stages without re-running the whole sequence.
- Mux the result back into a video.

Selective mode is only fully usable here. Automatic mode works in either
place and behaves identically.

---

## 5. What `star` Is Good and Not Good At

**Good at:**

- Static timelapses, clear skies, normal exposure times. Even
  `--clean-method automatic --detection-type mild` gets nearly all
  airplanes and satellites, with very few false positives.
- Long sequences (hundreds to thousands of frames). The sigma-clipped
  median gets dramatically more reliable as `N` grows.
- Sequences with mild camera drift. The RANSAC homography handles
  small, slow tripod settling.
- Preserving stars: even though stars are bright points, they appear
  in *every* frame at the same place after sky alignment, so they are
  by definition *not* outliers and survive the median.

**Not good at:**

- **Moving timelapses with anything bright below the horizon.** Without
  earth alignment, the median below the horizon collapses to "the
  original frame," subtraction is zero, and ground transients
  (headlights, distant aircraft, low-flying satellites near the
  horizon) pass through. The codebase is explicit about this in
  [`FrameAirplaneRemover.swift:5787`](StarCore/Sources/StarCore/FrameAirplaneRemover.swift:5787):
  if neither earth-aligned nor sky-aligned reference can be built,
  no subtraction image can be built either.
- **Fast-moving clouds.** Clouds change fast enough that a "clean
  reference" of a cloud isn't really clean — the median will smear.
  Selective mode is recommended in this case so the user can keep the
  cloud frames as-is.
- **Dawn / dusk.** Rapid global brightness changes confuse the
  subtraction step (the reference is dimmer than the original
  everywhere, not just at airplane trails), generating many false
  positives.
- **Very short sequences (< ~5 frames).** Too few samples for the
  sigma-clipped median to reject outliers reliably.
- **Meteors and bolides** — these *will* be removed in pure
  automatic mode because they look exactly like airplane trails to
  the classifier (single-frame bright streaks). Use
  `--clean-method automatic:true` to run the selective preservation
  pass that puts them back, or use `--clean-method selective` and
  approve them in the GUI.

---

## 6. Build & Distribution

`star` is Swift Package Manager based. The package layout:

- [`StarCore/`](StarCore/) — pure Swift core library, depends on
  `StarCpp`, `logging`, `Semaphore`. Contains all of `FrameAirplaneRemover`,
  the operation graph, blob/horizon code.
- [`StarCpp/`](StarCpp/) — pure C++/Swift bridge to OpenCV. Internally
  three targets: `StarCppCore` (C++ KHT), `starcpp_bridge` (the OpenCV
  wrapper), and `StarCpp` (a thin Swift façade).
- [`StarDecisionTrees/`](StarDecisionTrees/) — generated C++/Swift
  code containing the trained classifiers, compiled to a static
  library per platform.
- [`KHTSwift`](https://github.com/...) — external Swift package
  wrapping a C++ implementation of the Kernel Hough Transform.
- [`opencv/`](opencv/) — OpenCV is built locally as a static archive
  (`libopencv2.a`) for each target platform. Built in tree, not via
  a system package, so the binary is fully self-contained.
- [`ffmpeg-build/`](ffmpeg-build/), [`build-universal-ffmpeg.sh`](build-universal-ffmpeg.sh)
  — `ffmpeg` is built universal (arm64+x86_64 on macOS) and bundled
  in the app's `Resources` for video import/export.

### Per-platform release scripts

Both follow the same shape: build OpenCV statically, build the
decision-tree library, build the CLI, then package.

- [`release_darwin.sh`](release_darwin.sh): builds OpenCV → builds
  StarDecisionTrees → builds CLI → builds GUI → packages both as
  `.pkg` installers via `pkgbuild`/`productbuild`. Universal binaries
  for arm64+x86_64. Code-signed and notarized via `release_install.sh`
  inside the GUI directory.
- [`release_linux.sh`](release_linux.sh): builds OpenCV → builds
  StarDecisionTrees → builds the CLI → packages as a `.deb` via
  `dpkg-deb`. CLI only; no GUI on Linux. Requires Swift toolchain
  from swift.org plus the system dev packages
  (`cmake make pkg-config libeigen3-dev zlib1g-dev libpng-dev
  libtiff-dev libjpeg-dev`).

### What's bundled in a release

- The `star` CLI binary (statically linked against OpenCV and
  StarDecisionTrees).
- A bundled `ffmpeg` binary for video I/O.
- The compiled decision-tree static library, baked into the binary.

The result is a single drop-in installer per platform with no
external runtime dependencies beyond the OS itself.

---

## References

- Otsu, N. (1979). *A Threshold Selection Method from Gray-Level
  Histograms.* IEEE Trans. Systems, Man, and Cybernetics, 9(1).
- Canny, J. (1986). *A Computational Approach to Edge Detection.*
  IEEE PAMI, 8(6).
- Lowe, D. G. (2004). *Distinctive Image Features from Scale-Invariant
  Keypoints.* IJCV, 60(2).
- Alcantarilla, P. F., Nuevo, J., Bartoli, A. (2013). *Fast Explicit
  Diffusion for Accelerated Features in Nonlinear Scale Spaces*
  (AKAZE). BMVC.
- Fischler, M. A., Bolles, R. C. (1981). *Random Sample Consensus*
  (RANSAC). Comm. ACM, 24(6).
- Fernandes, L. A. F., Oliveira, M. M. (2008). *Real-time line
  detection through an improved Hough transform voting scheme*
  (Kernel Hough Transform). Pattern Recognition, 41(1).
- Howell, S. B. (2006). *Handbook of CCD Astronomy* (2nd ed.) —
  kappa-sigma clipping for astrophotographic stacking.
