# Cross-Platform Star: Swift Daemon + Kotlin/Compose GUI Design

**Status:** Authoritative design spec. Transport validated by CI spike (see §13).
**Audience:** An engineer (or agent) implementing a cross-platform desktop GUI for Star without rewriting
StarCore.
**History:** Supersedes the gRPC-based draft. The transport was changed to **protobuf-over-stdio** after a
two-round spike proved gRPC — and every socket transport — cannot build on Windows (details in §13 and in
`GRPC_WINDOWS_SPIKE_PLAN.md` / `GRPC_WINDOWS_SPIKE_ADDENDUM.md`, results in the `gprc_windows_test` repo's
`SPIKE_FINDINGS.md` + `SPIKE_ROUND2_RESULTS.md`).

---

## 1. Summary

Star's processing core (`StarCore`, Swift) and its low-level image code (`StarCpp`, C++/OpenCV) already build
and run on macOS, Linux, and Windows — the `cli/` tool proves this. Only the GUI is macOS-locked, because it is
SwiftUI + AppKit.

This design adds a **third StarCore client**: a **headless Swift daemon** (`stard`) that links `StarCore`
exactly like `cli/` does, but instead of running one batch job and exiting, it stays resident and serves
StarCore's capabilities over a **length-framed protobuf protocol on its own stdin/stdout pipes**. A
**Kotlin + Compose Multiplatform** desktop app spawns the daemon as a child process, drives it over those
pipes, and renders the UI.

Key properties of this architecture:

- **StarCore is reused verbatim.** No Swift→Kotlin FFI, no C++ migration. The daemon calls the same
  `ConfigManager` / `FrameAirplaneRemover` / `OutlierGroup` APIs the macOS GUI and CLI call.
- **The protobuf message set is the contract** between "what the GUI needs" and "what StarCore does." Every
  interaction the macOS GUI performs maps to one request method (§7).
- **No networking.** The daemon is a child process; communication is binary frames over its stdio pipes. No
  ports, no sockets, no localhost server, no firewall surface, no auth token. This is the only transport that
  builds on Windows (§13).
- **Images are exchanged by file path, not bytes.** Daemon and client share a scratch directory; the daemon
  writes previews/masks/output to scratch and returns paths. Only small structured data (config,
  outlier-group metadata, progress events) crosses the pipe (§8).

```
┌─────────────────────────────────────┐         ┌──────────────────────────────────────┐
│  Kotlin + Compose Multiplatform GUI  │         │  stard  (Swift headless daemon)        │
│  (child-process owner)               │         │  ├─ StdioTransport (read loop +        │
│                                      │  framed │  │    serialized writer)               │
│  ViewModels ─ Repos ─ StdioConn ─────┼─protobuf┼─▶├─ Dispatcher (method → handler)      │
│        │           (multiplexer)     │ over    │  ├─ SessionManager                     │
│        │                             │ pipes   │  └─▶ StarCore (ConfigManager,          │
│        ▼ reads image files           │ stdin/  │       FrameAirplaneRemover, OutlierGroup)│
└─────────┬────────────────────────────┘ stdout └───────────────┬──────────────────────┘
          │                                                      │ writes preview/mask/output
          ▼                                                      ▼
     ┌──────────────────────────────────────────────────────────────────┐
     │  Shared scratch filesystem (session dir): source frames, previews, │
     │  outlier label masks, rendered output, optional exported video      │
     └──────────────────────────────────────────────────────────────────┘
```

**Target platforms:** desktop only — macOS, Linux, Windows. (Android/iOS are out of scope: this model depends
on a co-resident native Swift process and a shared filesystem.)

---

## 2. Goals / Non-Goals

### Goals
- Full feature parity with the macOS GUI's core workflow: open input, run detection, **interactively review
  and edit per-frame outlier decisions**, render, and export.
- Zero forced changes to StarCore's algorithms. Additive StarCore changes only (§10).
- One Swift codebase serving three clients: `cli/`, macOS `gui/`, and the new daemon.
- A transport that builds and runs on all three desktop OSes (proven, §13).

### Non-Goals
- No mobile target.
- No rewrite of StarCore into C++ or Kotlin.
- No remote/multi-machine operation, and **no multi-client** (stdio is one parent ↔ one child; see §4).
- The daemon is an implementation detail of the app, not a public API.

---

## 3. Why a daemon, and why stdio

**Why a resident daemon (vs. driving the batch CLI):** the CLI is fire-and-forget and cannot serve a single
frame's outlier groups for interactive keep/remove editing, nor stream typed progress. A resident daemon holds
the live `FrameAirplaneRemover` graph in memory and answers per-frame requests. StarCore's existing `Callbacks`
struct (`frameStateChangeCallback`, `frameSavingStateChangeCallback`, `exisingFrameStateChangeCallback`,
`frameOutliersLoadedCallback`) already models exactly the events a GUI needs (§6.4).

**Why stdio (vs. gRPC / TCP):** a CI spike established that on Windows, with Swift 6.1:
1. grpc-swift 2.2.3 won't compile (missing `ucrt` import — patchable), and
2. **even patched, swift-nio's `NIOPosix` socket layer itself won't compile** (`IPPROTO`/`BinaryFloatingPoint`
   cast; `UnsafeMutableRawPointer` non-`Sendable`).

`NIOPosix` underpins gRPC *and* any raw-TCP transport, so all socket options are blocked on Windows. A
length-framed protobuf channel over the daemon's stdin/stdout depends only on `SwiftProtobuf` (pure Swift) and
the Swift standard library — it **builds and runs on Windows/Linux/macOS** (spike Q7, all green). It also needs
no port, no handshake, and no auth. The cost is that we implement the request multiplexing gRPC gave us for
free (§5) — a well-understood pattern (LSP/DAP servers do exactly this).

---

## 4. Process model & lifecycle

1. **Spawn.** The Kotlin app bundles the `stard` binary for the current OS (§11) and launches it as a child:
   `stard --scratch <dir> [--log-file <path>]`. The app holds the child's `stdin`/`stdout`/`stderr`.
2. **Channels.**
   - `stdin` (app → daemon) and `stdout` (daemon → app) carry **binary framed protobuf only** (§5). Nothing
     else may be written to stdout.
   - `stderr` carries human-readable daemon logs. The daemon routes all `StarCore` logging to stderr and/or
     `--log-file`; **never to stdout** (it would corrupt the frame stream — the LSP rule).
3. **Binary stdio.** On startup the daemon calls `setBinaryStdIO()` (validated snippet, §6.3) so Windows does
   not translate `\n`↔`\r\n` or treat `0x1A` as EOF. Without it, binary frames corrupt on Windows.
4. **No handshake / no port / no token.** The parent already owns the pipes; there is no network surface to
   discover or secure. The first frame the app sends is a real request (e.g. `Daemon.Hello`).
5. **Shutdown.** Two paths, both clean:
   - Graceful: app sends `Daemon.Shutdown`; daemon finishes in-flight writes and exits.
   - Implicit: when the app exits, the child's `stdin` reaches **EOF**; the daemon's read loop ends and it
     exits. This removes any need for an orphan-watchdog.
6. **Crash handling.** If the daemon dies, the app sees `stdout` EOF / process exit, surfaces "engine stopped,"
   and offers restart. Sessions are reconstructible from their on-disk `config.json` in scratch, so the app can
   re-open the last session after a restart.
7. **One daemon, one client.** A single duplex pipe pair = exactly one client. Multiple *sessions* (sequences)
   inside that one daemon are fine (routed by `session_id`, §7); multiple independent clients are not supported
   and not needed.

---

## 5. Wire protocol (what gRPC used to do for us)

### 5.1 Framing
Each message is a **4-byte big-endian unsigned length** followed by that many bytes of a serialized `Envelope`
protobuf. Reads/writes use the validated helpers (§6.3): `readFrame()` returns `nil` on EOF; `writeFrame()`
uses `FileHandle.write` (unbuffered — no flush needed).

### 5.2 The Envelope
```proto
syntax = "proto3";
package star.v1;

message Envelope {
  uint64 id = 1;                 // correlates a request with its response(s)
  enum Kind {
    REQUEST      = 0;            // client → daemon: invoke `method` with `payload`
    RESPONSE     = 1;            // daemon → client: unary result for `id`
    ERROR        = 2;            // daemon → client: failure for `id` (see `error`)
    STREAM_ITEM  = 3;            // daemon → client: one item of a server-stream for `id`
    STREAM_END   = 4;            // daemon → client: server-stream for `id` is complete
    CANCEL       = 5;            // client → daemon: cancel the in-flight request `id`
    NOTIFICATION = 6;            // daemon → client: unsolicited (id = 0). reserved; unused in v1
  }
  Kind   kind    = 2;
  string method  = 3;            // e.g. "Outlier.SetDecisions" (REQUEST only)
  bytes  payload = 4;            // serialized request or response message (§7)
  string error   = 5;            // human-readable failure (ERROR only)
  int32  error_code = 6;         // optional machine code (ERROR only)
}
```

### 5.3 Call shapes
- **Unary:** client sends `REQUEST{id, method, payload=Req}`; daemon replies with exactly one
  `RESPONSE{id, payload=Resp}` or one `ERROR{id, ...}`.
- **Server-streaming:** client sends `REQUEST{id, method, payload=Req}`; daemon emits zero or more
  `STREAM_ITEM{id, payload=Item}` then one `STREAM_END{id}` (or an `ERROR{id}` to abort). Progress streams
  (e.g. `Processing.StreamProgress`) use this shape and stay open for the duration of processing.
- **Cancellation:** client sends `CANCEL{id}`; daemon cancels the Swift `Task` servicing that `id` and emits a
  terminal `ERROR{id, error:"cancelled"}` or `STREAM_END{id}`.
- There are **no client-streaming or bidi RPCs** in v1 (not needed). Multiple unary edits are sent as separate
  requests; they may be in flight concurrently.

`id` is client-generated, monotonically increasing, unique while in flight. The daemon never originates `id`s
in v1 (NOTIFICATION reserved for later).

### 5.4 The multiplexer (required on both sides)
One duplex pipe carries everything, so interactive requests interleave with long-running progress streams. Both
ends implement the same small machine:

- **Reader loop:** a single task continuously reads frames and dispatches by `id`:
  - client side: `RESPONSE`/`ERROR` complete a pending `Deferred`; `STREAM_ITEM`/`STREAM_END` push onto the
    `Flow`/`Channel` registered for that `id`.
  - daemon side: `REQUEST` is dispatched to a handler in its own `Task` keyed by `id`; `CANCEL` cancels that
    `Task`.
- **Serialized writer:** a single owner of the outbound pipe. Handlers/callers never write the pipe directly —
  they enqueue completed `Envelope`s onto an async channel that the lone writer drains and frames in order.
  This guarantees frames never interleave-corrupt.
- **Head-of-line note:** because one writer drains one pipe, a blocked write (slow reader) stalls all outbound
  frames. For a local single-client GUI with small, infrequent frames (paths + metadata, never image bytes)
  this is a non-issue; document it and keep the outbound channel buffered.
- **Registries:** daemon keeps `[id: Task]` (for cancellation); client keeps `[id: Deferred]` and
  `[id: Channel]`. Clean up on terminal frames.

### 5.5 Method registry
`method` strings are `"Namespace.Method"`. The table in §7 is the authoritative list; each row states the
request message, the response/item message, and whether it's unary or server-streaming.

---

## 6. The Swift daemon (`stard`)

### 6.1 Package / target layout
New SwiftPM package mirroring the standalone-tool pattern in the repo, with the message types isolated so the
daemon never transitively pulls in grpc-swift or swift-nio:

```
daemon/
  Package.swift                 # swift-tools-version: 6.0 (build with 6.1+; see §11)
  Sources/
    StarDaemonMessages/         # generated swift-protobuf types ONLY (depends on SwiftProtobuf)
      star.pb.swift             # generated & committed (Visibility=Public)
    stard/
      main.swift                # @main: parse --scratch/--log-file, setBinaryStdIO(), run loop
      StdioTransport.swift      # read loop + serialized writer + framing (§6.3)
      Dispatcher.swift          # method string -> handler; id -> Task registry; CANCEL handling
      SessionManager.swift      # [SessionId: Session]
      Session.swift             # wraps ConfigManager + the FrameAirplaneRemover graph for one sequence
      EventBridge.swift         # StarCore Callbacks/observers -> STREAM_ITEM frames
      Mapping.swift             # StarCore types <-> generated proto types
      handlers/
        DaemonHandlers.swift  SessionHandlers.swift  SequenceHandlers.swift
        FrameHandlers.swift   OutlierHandlers.swift  ProcessingHandlers.swift  ExportHandlers.swift
  proto/                        # the .proto files (single source of truth, shared with the Kotlin app)
```

### 6.2 Dependencies (`daemon/Package.swift`)
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StarDaemon",
    platforms: [.macOS("15.0")],   // string form; .v15 enum is absent on CI toolchains (spike note)
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(name: "StarCore", path: "../StarCore"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    ],
    targets: [
        .target(name: "StarDaemonMessages",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .executableTarget(name: "stard",
            dependencies: [
                "StarDaemonMessages",
                .product(name: "StarCore", package: "StarCore"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]),
    ]
)
```
**No grpc-swift, no swift-nio.** The spike confirmed `SwiftProtobuf` alone builds and runs on Windows. Generate
stubs with `Visibility=Public` (spike `SPIKE_FINDINGS.md`) and commit them. End `main.swift` with the standard
teardown (`await TaskWaiter.shared.finish()` + `await logging.gremlin.finishLogging()`).

### 6.3 Validated transport primitives (carry from the spike's `StdioEcho`)
```swift
import Foundation
#if os(Windows)
import ucrt
#endif

func setBinaryStdIO() {                      // call ONCE at startup, before any read/write
#if os(Windows)
    let O_BINARY: Int32 = 0x8000
    _ = _setmode(_fileno(stdin),  O_BINARY)
    _ = _setmode(_fileno(stdout), O_BINARY)
#endif
}

let inHandle = FileHandle.standardInput, outHandle = FileHandle.standardOutput

func readExactly(_ n: Int) -> Data? {        // nil on EOF / short final frame
    var buf = Data()
    while buf.count < n {
        let chunk = inHandle.readData(ofLength: n - buf.count)
        if chunk.isEmpty { return nil }
        buf.append(chunk)
    }
    return buf
}
func readFrame() -> Data? {
    guard let len = readExactly(4) else { return nil }
    return readExactly(len.reduce(0) { ($0 << 8) | Int($1) })   // 4-byte big-endian
}
func writeFrame(_ data: Data) {              // FileHandle.write is unbuffered; serialize all callers (§5.4)
    let n = UInt32(data.count).bigEndian
    var header = Data(count: 4)
    withUnsafeBytes(of: n) { header.replaceSubrange(0..<4, with: $0) }
    outHandle.write(header); outHandle.write(data)
}
```
`writeFrame` must be called only from the single writer task (§5.4). PID, if ever needed for logs, is
`ProcessInfo.processInfo.processIdentifier` (not `getpid()`).

### 6.4 Session lifecycle & event bridging
`Session` is the daemon's analogue of the CLI's `Processor` setup (`cli/Sources/star/StarCli.swift`,
`Processor.swift`). On `Session.OpenSequence`/`OpenConfig` it:
1. Registers classifiers exactly as the CLI does:
   ```swift
   await StarCore.currentClassifier.set(for: .all)      { OutlierGroupForestClassifier_2436760d() }
   await StarCore.currentClassifier.set(for: .isolated) { OutlierGroupForestClassifier_f9f52500() }
   ```
2. Builds a `ConfigManager` (new `Config`, or loaded from `config.json`); sets `constants`/detection type and
   scratch/output paths.
3. Wires a `Callbacks` whose closures push events into the session's progress stream.
4. Constructs the frame graph but does **not** start processing until `Processing.Start` is called.

`EventBridge` converts StarCore's callbacks/observers into `STREAM_ITEM` frames on the open
`Processing.StreamProgress` request (same mapping as before):

| StarCore callback | `ProgressEvent` variant |
|---|---|
| `frameStateChangeCallback(frame, FrameProcessingState)` | `frame_state` |
| `frameSavingStateChangeCallback(frame, old, new)` | `frame_saving_state` |
| `exisingFrameStateChangeCallback(frameIndex)` | `frame_existing` |
| `frameOutliersLoadedCallback(idx, OutlierLoadingState)` | `outliers_loaded` |
| `ProgressCallback` (video decode/ffmpeg) | `io_progress` |

StarCore is actor-based; handlers `await` into StarCore naturally. Long operations are server-streams, so the
read loop never blocks.

---

## 7. The message contract (methods + messages)

Protobuf 3, package `star.v1`. Filenames in messages are **absolute paths on the shared filesystem** (§8).
This is the authoritative method list; the daemon's `Dispatcher` registers exactly these strings.

### 7.1 Method registry
| `method` | Request | Response / Stream item | Shape |
|---|---|---|---|
| `Daemon.Hello` | `HelloRequest` | `HelloResponse` | unary |
| `Daemon.Shutdown` | `ShutdownRequest` | `ShutdownResponse` | unary |
| `Session.OpenVideo` | `OpenVideoRequest` | `OpenProgress` (item), final `SessionInfo` via `STREAM_END` payload-less; send `SessionInfo` as last `STREAM_ITEM` | server-stream |
| `Session.OpenSequence` | `OpenSequenceRequest` | `SessionInfo` | unary |
| `Session.OpenConfig` | `OpenConfigRequest` | `SessionInfo` | unary |
| `Session.Close` | `CloseSessionRequest` | `CloseSessionResponse` | unary |
| `Session.List` | `ListSessionsRequest` | `ListSessionsResponse` | unary |
| `Sequence.GetConfig` | `SessionRef` | `Config` | unary |
| `Sequence.UpdateConfig` | `UpdateConfigRequest` | `Config` | unary |
| `Frame.Get` | `FrameRef` | `FrameInfo` | unary |
| `Frame.GetPreview` | `GetFramePreviewRequest` | `ImageRef` | unary |
| `Frame.GetOutlierLabelImage` | `FrameRef` | `ImageRef` | unary |
| `Frame.SetCleanMethod` | `SetFrameCleanMethodRequest` | `FrameInfo` | unary |
| `Outlier.List` | `FrameRef` | `OutlierGroupList` | unary |
| `Outlier.SetDecisions` | `SetOutlierDecisionsRequest` | `SetOutlierDecisionsResponse` | unary |
| `Outlier.RenderFrame` | `FrameRef` | `ImageRef` | unary |
| `Processing.Start` | `StartProcessingRequest` | `StartProcessingResponse` | unary |
| `Processing.StreamProgress` | `SessionRef` | `ProgressEvent` | server-stream |
| `Processing.Cancel` | `SessionRef` | `CancelResponse` | unary |
| `Export.RenderSequence` | `SessionRef` | `ProgressEvent` | server-stream |
| `Export.Video` | `ExportVideoRequest` | `ProgressEvent` | server-stream |

> `Processing.Cancel` cancels the *processing job*; the transport-level `CANCEL` envelope (§5.3) cancels an
> individual in-flight request/stream. They are different — keep both.

### 7.2 Messages
```proto
// ---- Daemon ----
message HelloRequest  { string client_version = 1; }
message HelloResponse { string daemon_version = 1; string scratch_dir = 2; }
message ShutdownRequest {}  message ShutdownResponse {}

// ---- Session ----
message OpenVideoRequest   { string video_path = 1; Config initial_config = 2; }
message OpenSequenceRequest { string sequence_dir = 1; Config initial_config = 2; }
message OpenConfigRequest   { string config_json_path = 1; }
message OpenProgress {
  oneof kind { IoProgress progress = 1; SessionInfo done = 2; }
}
message SessionInfo {
  string session_id = 1; int32 frame_count = 2;
  int32 image_width = 3; int32 image_height = 4; int32 components_per_pixel = 5;
  Config config = 6; string scratch_session_dir = 7;
}
message CloseSessionRequest { string session_id = 1; }  message CloseSessionResponse {}
message ListSessionsRequest {}  message ListSessionsResponse { repeated SessionInfo sessions = 1; }
message SessionRef { string session_id = 1; }

// ---- Config (mirror StarCore.Config) ----
message UpdateConfigRequest { string session_id = 1; Config config = 2; }
message Config {
  string output_path = 1; string temp_output_path = 2;
  CleanMethod clean_method = 3; DetectionType detection_type = 4;
  bool horizon_detection_enabled = 5; bool tripod_head_was_moving = 6;
  int32 number_of_frames_to_process_concurrently = 7;
  int32 ignore_lower_pixels = 8;                       // -1 = unset
  map<int32, CleanMethod> pixel_replacement_overrides = 9;
  map<int32, int32> static_neighbor_frame_overrides = 10;
  map<int32, int32> aligned_neighbor_frame_overrides = 11;
  bool write_outlier_group_files = 12; bool write_frame_preview_files = 13;
  // extend to match Config.swift as the UI exposes more
}
enum CleanMethod { CLEAN_AUTOMATIC = 0; CLEAN_AUTOMATIC_TRUE = 1; CLEAN_SELECTIVE = 2; }
enum DetectionType { DETECTION_STRONG = 0; DETECTION_MODERATE = 1; /* mirror DetectionType.swift */ }

// ---- Frame ----
message FrameRef { string session_id = 1; int32 frame_index = 2; }
message FrameInfo {
  int32 frame_index = 1; FrameProcessingState state = 2;
  int32 num_positive_outliers = 3; int32 num_negative_outliers = 4; int32 num_undecided_outliers = 5;
  CleanMethod clean_method = 6;
}
message GetFramePreviewRequest { string session_id = 1; int32 frame_index = 2; FrameViewMode view_mode = 3; }
enum FrameViewMode { VIEW_ORIGINAL = 0; VIEW_PROCESSED = 1; VIEW_SUBTRACTION = 2; VIEW_VALIDATION = 3; }
message ImageRef { string path = 1; int32 width = 2; int32 height = 3; string format = 4; }
message SetFrameCleanMethodRequest { string session_id = 1; int32 frame_index = 2; CleanMethod clean_method = 3; }

// Mirror StarCore.FrameProcessingState 1:1 (Codable/Hashable, ~40 cases). Keep numeric values stable.
enum FrameProcessingState {
  FPS_UNPROCESSED = 0; FPS_HORIZON_DETECTION = 1; FPS_DETECTING_BLOBS = 2;
  FPS_FIRST_CLASSIFICATION = 3; FPS_READY_FOR_INTERFRAME = 4; FPS_SECOND_CLASSIFICATION = 5;
  FPS_OUTLIER_PROCESSING_COMPLETE = 6; FPS_WRITING_OUTPUT_FILE = 7; FPS_COMPLETE = 8;
  // ...complete from FrameProcessingState.swift
}

// ---- Outlier ----
message OutlierGroupList { repeated OutlierGroup groups = 1; }
message OutlierGroup {
  uint32 id = 1; uint64 size = 2; BoundingBox bounds = 3; uint64 brightness = 4;
  RemoveReason should_remove = 5; double classification_score = 6; Line line = 7;
}
message BoundingBox { int32 min_x = 1; int32 min_y = 2; int32 max_x = 3; int32 max_y = 4; }
message Line { double theta = 1; double rho = 2; int32 votes = 3; }
enum RemoveReason {
  RR_UNDECIDED = 0; RR_USER_REMOVE = 1; RR_USER_KEEP = 2; RR_CLASSIFIER_REMOVE = 3; RR_CLASSIFIER_KEEP = 4;
  // ...mirror RemoveReason.swift
}
message SetOutlierDecisionsRequest {
  string session_id = 1; int32 frame_index = 2; repeated OutlierDecision decisions = 3; bool rerender = 4;
}
message OutlierDecision { uint32 group_id = 1; RemoveReason decision = 2; }
message SetOutlierDecisionsResponse { FrameInfo frame = 1; ImageRef preview = 2; }  // preview set iff rerender

// ---- Processing / Export ----
message StartProcessingRequest { string session_id = 1; int32 start_index = 2; int32 end_index = 3; }
message StartProcessingResponse {}  message CancelResponse {}
message ProgressEvent {
  oneof kind {
    FrameStateEvent  frame_state = 1; FrameSavingEvent frame_saving_state = 2;
    int32            frame_existing = 3; OutliersLoaded outliers_loaded = 4;
    IoProgress       io_progress = 5; SequenceStateEvent sequence_state = 6;
  }
}
message FrameStateEvent  { int32 frame_index = 1; FrameProcessingState state = 2; }
message FrameSavingEvent { int32 frame_index = 1; int32 old_state = 2; int32 new_state = 3; }
message OutliersLoaded   { int32 frame_index = 1; int32 state = 2; }
message IoProgress       { int32 current = 1; int32 total = 2; string output_dir = 3; }
message SequenceStateEvent { string state = 1; }
message ExportVideoRequest { string session_id = 1; string output_video_path = 2; }
```

---

## 8. Image & data exchange conventions

**Rule: structured data over the pipe, pixels over the filesystem.**

- **Scratch layout.** Each session owns `…/star-scratch/<session_id>/` containing: `source/` (decoded/source
  frames), `previews/`, `labels/` (outlier-id label PNGs), `output/` (final frames), and `config.json`. The
  daemon owns the scratch root and reports it (`HelloResponse.scratch_dir`, `SessionInfo.scratch_session_dir`).
- **Previews.** `Frame.GetPreview` / `Outlier.RenderFrame` write a display PNG (8-bit) to `previews/` and
  return its `ImageRef.path`; the client loads it directly.
- **Outlier overlays without round-trips.** `Frame.GetOutlierLabelImage` returns a 16-bit single-channel label
  image (pixel value = group id, 0 = none). The client loads it once per frame, builds an in-memory hit-test
  map for clicks, and **tints keep/remove locally in Compose** as the user toggles — no request per click.
  Only when the user wants a true painted preview does the client call `Outlier.SetDecisions{rerender:true}` or
  `Outlier.RenderFrame`.
- **Formats.** Source frames keep native depth (8/16-bit TIFF/PNG per `PixelatedImage`); display previews are
  8-bit PNG. State exact formats in proto comments so the Kotlin side decodes correctly.
- **Path discipline.** Absolute paths everywhere; the client assumes no layout beyond what messages return.

This is the §1 "filenames instead of image bytes" decision made concrete, and it is also why pipe throughput
is a non-issue (§5.4): only metadata crosses the wire.

---

## 9. The Kotlin / Compose client

### 9.1 Modules (Gradle)
```
star-desktop/
  build.gradle.kts                 # Compose Multiplatform (desktop/JVM) + protobuf-kotlin
  proto/                           # the SAME .proto files (single source of truth; symlink/submodule)
  src/jvmMain/kotlin/
    proto/                         # generated protobuf-kotlin/-java message types (NO grpc plugin)
    engine/
      DaemonProcess.kt             # spawn stard, own its stdin/stdout/stderr, supervise/restart
      StdioConnection.kt           # framing + reader loop + serialized writer + id registries (§5.4)
      StarClient.kt                # typed call()/serverStream() per §7 method
    data/
      SessionRepository.kt         # open/close, config; StateFlow<SessionInfo>
      ProcessingRepository.kt      # Start/Cancel; collects StreamProgress into StateFlow
      OutlierRepository.kt         # list/set decisions; caches label images
      ImageCache.kt                # loads preview/label files into Compose ImageBitmap
    ui/
      App.kt  OpenScreen.kt  ProcessingScreen.kt  FrameReviewScreen.kt  ExportScreen.kt
```

### 9.2 The client transport (mirror of §5.4)
- **No gRPC libraries.** Use `com.google.protobuf:protobuf-kotlin` for messages only.
- `StdioConnection` reads the daemon's `stdout` on a dedicated thread/coroutine: parse 4-byte length + Envelope,
  dispatch by `id`. It exposes:
  ```kotlin
  suspend fun <Req: Message, Resp: Message> call(method: String, req: Req, parser: Parser<Resp>): Resp
  fun <Req: Message, Item: Message> serverStream(method: String, req: Req, parser: Parser<Item>): Flow<Item>
  fun cancel(id: Long)   // sends CANCEL{id}
  ```
- Outbound writes go through a single `Channel<ByteArray>` drained by one writer coroutine onto the daemon's
  `stdin` (serialized writer). `id`s are an `AtomicLong`. Pending unary calls register a `CompletableDeferred`;
  streams register a `Channel`/`SendChannel` that backs the returned `Flow`. Terminal frames clean up the
  registry. JVM `Process` stdio is binary-clean on Windows (the binary-mode concern is Swift-side only).
- The daemon's `stderr` is drained to the app log.

### 9.3 UI ↔ StarCore mapping (parity with macOS GUI)
| macOS GUI behavior | Kotlin path |
|---|---|
| Open video / sequence / config | `Session.OpenVideo` (stream) / `OpenSequence` / `OpenConfig` |
| Run processing, watch per-frame state grid | `Processing.Start` + `Processing.StreamProgress` → grid |
| Scrub frames, view original/processed | `Frame.GetPreview` + `ImageCache` |
| See outlier groups overlaid | `Frame.GetOutlierLabelImage` + `Outlier.List`, tinted in Compose |
| Click a group to keep/remove | local hit-test on label image → `Outlier.SetDecisions` |
| Per-frame clean method override | `Frame.SetCleanMethod` |
| Render / save / export video | `Outlier.RenderFrame` / `Export.RenderSequence` / `Export.Video` |
| Preferences, recent files | **client-local** (JVM `Preferences`/JSON) — not StarCore state |

GUI-resident logic from the macOS app (video playback loop, frame-navigation strategies, recent files) is
reimplemented client-side in Kotlin; anything that touches StarCore (ffmpeg orchestration) lives daemon-side
(`Export.*`, reusing `VideoConvert`).

---

## 10. Required StarCore changes (small & additive)

- **Headless label-image rendering.** Add a method to render a frame's outlier-id label image (16-bit) to a
  path using `MatWrapper`/OpenCV — **not** the `#if canImport(AppKit)`/`CoreGraphics` visualization paths, so
  it runs on Linux/Windows. Audit `OutlierGroup.swift`, `ImageAccessor.swift`, `PixelatedImage.swift` for any
  AppKit/CoreGraphics path reachable from the daemon and provide an OpenCV equivalent. **This is the change
  with the most platform risk; verify early (§13, Phase 0).**
- **Headless preview rendering.** Confirm `PixelatedImage` → PNG works without AppKit on Linux/Windows (it
  should via `mat.write(to:)` / OpenCV `imwrite`; AppKit paths are `#if canImport(AppKit)` only).
- **Outlier-group accessors.** Ensure `id`, `bounds`, `size`, `brightness`, `shouldRemove`, classification
  score, and `line` are reachable (mostly already `nonisolated let` + async getters; add score/line getters if
  missing).
- **Enum stability.** `FrameProcessingState`, `RemoveReason`, `CleanMethod`, `DetectionType`,
  `SequenceProcessingState` are the proto-enum sources of truth — add a comment in each Swift file pointing at
  `proto/star.proto` so they stay in sync, and a test asserting case counts match (§12).
- **No change** to detection/classification algorithms.

---

## 11. Build & packaging

- **Toolchain.** Build with **Swift 6.1+** (6.0's C importer hits an MSVC `ucrt` cyclic-dependency on newer
  Windows images — spike finding). On Windows use **VS 2022 / `windows-2022`**, not VS 2026 (Swift 6.x ships
  Clang 19; VS 2026 STL headers demand Clang ≥ 20 — spike finding).
- **Daemon binaries.** Build `stard` per OS via the existing release-script pattern (`cli/release*.sh`,
  `cli/star_installer.nsi`). StarCpp links the vendored OpenCV static lib already (`opencv/lib/{macos,linux,windows}`).
- **Bundling.** The Compose Desktop distributable (jpackage / `nativeDistributions`) ships the matching `stard`
  binary; the app resolves it next to itself and spawns it.
- **ffmpeg.** Bundle/locate per platform as the macOS GUI does; the daemon shells out via `StarCore.VideoConvert`.
- **Single proto source.** `proto/star.proto` is authoritative in one place; both `daemon/` and `star-desktop/`
  generate from it (submodule/symlink/CI copy). Drift here = silent wire breakage. Generate Swift stubs with
  `Visibility=Public` using the plugin built from the resolved checkout (spike `SPIKE_FINDINGS.md`).

---

## 12. Testing strategy

1. **Enum parity test (Swift).** Assert each proto enum's case count/values match the Swift enum
   (`FrameProcessingState.allCases.count == <proto count>`, etc.).
2. **Transport unit tests (both sides).** Frame round-trip; multiplexer correctness — interleaved unary +
   stream on one pipe, cancellation, EOF handling. Reuse the spike's `StdioEcho` framing as the basis.
3. **Daemon integration tests (Swift).** Spawn `stard`, drive each method against a tiny fixture sequence,
   assert outputs land in scratch and progress streams.
4. **Golden-output parity.** Run the same fixture through `cli/` and through the daemon; assert identical
   output frames. Proves the daemon didn't change behavior.
5. **Kotlin client tests.** Against a real `stard` in CI (Linux + Windows): full open→process→edit→render flow.
   Headless Compose test for the review screen's hit-testing/overlay logic.
6. **Crash/restart.** Kill `stard` mid-stream; assert the client detects stdout EOF, recovers, re-opens from
   config.

---

## 13. Risks (status after the spike)

1. ~~gRPC on Windows~~ — **resolved by removing gRPC.** The spike proved gRPC and all NIO socket transports
   fail to build on Windows; stdio (SwiftProtobuf only) builds and runs on all three OSes. The transport risk
   is retired.
2. **Headless image rendering on Linux/Windows** — now the top open risk. Any outlier-overlay/preview path that
   touches AppKit/CoreGraphics must be replaced with an OpenCV (`MatWrapper`) path. Verify in Phase 0 (§14).
3. **CoreML tile classifier is Apple-only** (`TileClassifier.swift`, `#if canImport(CoreML)`). The daemon on
   Linux/Windows must run the same path the CLI already uses there (the `StarDecisionTrees` forest, pure Swift,
   cross-platform). Confirm the daemon never depends on the CoreML path for correctness.
4. **OpenCV per-platform static libs / Eigen** — already solved for `cli/`; the daemon inherits it via StarCpp.
   Ensure the daemon links the same way.
5. **Head-of-line blocking on the single pipe** (§5.4) — acceptable for one local client with metadata-only
   frames; keep the outbound channel buffered and never put image bytes on the wire.
6. **Mobile out of scope** — unchanged.

**Worth filing upstream (non-blocking, good citizenship):** grpc-swift `RetryDelaySequence.swift` `ucrt`
one-liner; swift-nio Windows build gaps in `NIOPosix/System.swift`, `Thread.swift`, `ThreadWindows.swift`.

---

## 14. Phased implementation plan

- **Phase 0 — De-risk (days).** (a) Confirm StarCore renders a frame preview **and** an outlier-id label image
  headlessly on Linux *and* Windows with no AppKit/CoreGraphics (the §10 / risk #2 item). (b) Stand up a
  `daemon/` skeleton that links StarCore + SwiftProtobuf and builds on `windows-2022` with Swift 6.1. Carry the
  validated `setBinaryStdIO()` + framing helpers (§6.3). Go/no-go on headless rendering.
- **Phase 1 — Transport + skeleton.** `StdioTransport` (read loop + serialized writer + multiplexer),
  `Dispatcher`, `Daemon.Hello`, `Session.OpenSequence`, `Sequence.GetConfig`. Kotlin `StdioConnection` +
  `DaemonProcess`; app spawns daemon and completes a `Hello` round-trip. Transport unit tests (§12.2).
- **Phase 2 — Batch path.** `Processing.Start` + `Processing.StreamProgress`; `Frame.GetPreview`;
  `Export.RenderSequence`. Compose: open → process (progress grid) → view results. Golden-output parity vs CLI.
  *(This alone ships a cross-platform Star.)*
- **Phase 3 — Interactive editing.** `Outlier.*` + `Frame.GetOutlierLabelImage`; Compose review screen with
  overlay + keep/remove + per-frame clean method + `Outlier.RenderFrame`.
- **Phase 4 — Video in/out.** `Session.OpenVideo` + `Export.Video` (ffmpeg).
- **Phase 5 — Polish.** Recent files, preferences, crash recovery, per-OS packaging/installers.

---

## 15. Open questions
1. Single-session daemon (simplest) or multi-session from the start? The contract supports multi (`session_id`);
   v1 may assume one active session.
2. ffmpeg orchestration in the daemon (`Export.*`, reuses `VideoConvert`) vs. client — recommend daemon, to keep
   all StarCore-adjacent logic in one place.
3. Label-image overlay (recommended, fewer round-trips) vs. daemon-rendered colorized overlays — confirm with a
   quick UX spike.
4. Does the macOS GUI eventually re-point at the daemon too (one client model)? Out of scope here, but the
   contract allows it.
