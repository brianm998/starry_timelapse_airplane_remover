# Spike Addendum: Patched gRPC on Windows + Protobuf-over-stdio

**Status:** Handoff spec — second round of the transport de-risk.
**Prereqs:** Read `GRPC_WINDOWS_SPIKE_PLAN.md` (round 1 plan) and `/Users/brian/git/gprc_windows_test/SPIKE_FINDINGS.md`
(round 1 results) first. This addendum extends the **same** spike repo (`brianm998/gprc_windows_test`).
**Audience:** The agent continuing the spike.

---

## 0. Why a second round

Round 1 proved grpc-swift 2.2.3 fails to **compile** on Windows, but for a trivial reason: one file
(`GRPCCore/.../RetryDelaySequence.swift`) is missing `#elseif canImport(ucrt) / public import ucrt` and hits
`#error("Unsupported OS")`. Everything else compiled, and **swift-nio compiled fine** — so we never learned
whether gRPC actually *runs* on Windows, only that it didn't build.

That leaves two things unknown, and this addendum answers both:

- **Q6 — Patched gRPC:** with the one-line `ucrt` fix applied, does gRPC **build _and_ run** (unary + streaming
  + the stdout handshake) on Windows? This tells us if the gRPC path is salvageable via a vendored fork.
- **Q7 — Protobuf-over-stdio:** does a Swift program doing **binary, length-framed protobuf over its own
  stdin/stdout** run on Windows? This validates the recommended fallback transport — one that uses **no NIO
  networking at all**, so it's immune to any deeper NIO-on-Windows runtime problem.

Why both matter together: gRPC **and** any "custom protobuf over a TCP socket" option both ride swift-nio's
networking stack. If NIO networking has a runtime issue on Windows (Q6 would expose it), socket transports are
suspect — but **stdio pipes don't touch NIO networking** (Q7), so they remain safe. We want to know which
lane we're in before the daemon is built.

> Carry over the environment lessons from round 1 (these are not re-litigated here):
> **Swift 6.1**, **`windows-2022`** (not `windows-latest`/VS2026), **`macos-15`**, `.macOS("15.0")` string form
> in `Package.swift`, `ProcessInfo.processInfo.processIdentifier` for PID, and `FileHandle.standardError` for
> logs. Stubs must be generated with `Visibility=Public` using the plugin built from the resolved
> `grpc-swift-protobuf` checkout (see SPIKE_FINDINGS.md "Stub generation").

---

## Part A — Q6: does patched gRPC run on Windows?

### A.1 Approach: patch the checkout in CI (no fork needed for the spike)

For a throwaway spike, the fastest way to answer "if the one line were fixed, would it work?" is to patch the
resolved checkout in place, between `swift package resolve` and `swift build`. (For the *real* project you'd
instead point `Package.swift` at a fork — see A.4 — but that's not needed to get the answer.)

### A.2 `scripts/patch_grpc_ucrt.py`
```python
#!/usr/bin/env python3
"""Insert the missing ucrt import into grpc-swift's RetryDelaySequence.swift in the resolved checkout.
Idempotent; safe to run before `swift build`. Must run AFTER `swift package resolve`."""
import os, sys

target = os.path.join(".build", "checkouts", "grpc-swift",
                      "Sources", "GRPCCore", "Call", "Client", "Internal",
                      "RetryDelaySequence.swift")

if not os.path.exists(target):
    print(f"FAIL: {target} not found — did `swift package resolve` run?"); sys.exit(2)

src = open(target, encoding="utf-8").read()

if "canImport(ucrt)" in src:
    print("already patched"); sys.exit(0)

needle = "#elseif canImport(Musl)\npublic import Musl\n#else"
repl   = "#elseif canImport(Musl)\npublic import Musl\n#elseif canImport(ucrt)\npublic import ucrt\n#else"

if needle not in src:
    # Be tolerant of line-ending / whitespace drift across grpc-swift versions.
    print("WARN: exact needle not found; dumping the import block for manual inspection:")
    import re
    m = re.search(r"#if canImport\(Darwin\).*?#endif", src, re.S)
    print(m.group(0) if m else "(import block not found)")
    sys.exit(3)

open(target, "w", encoding="utf-8").write(src.replace(needle, repl))
print(f"patched {target}")
```

### A.3 CI job (add to `.github/workflows/spike2.yml`, see §C)
The job is the round-1 `build-and-run` job with one extra step inserted between resolve and build:
```yaml
      - name: Resolve
        run: swift package resolve
      - name: Patch grpc-swift ucrt import
        run: python scripts/patch_grpc_ucrt.py
      - name: Build
        run: swift build -v
      - name: Run two-process spike (unary + streaming + handshake)
        run: python scripts/run_spike.py     # reuse the round-1 harness unchanged
```
This reuses the round-1 `SpikeServer`/`SpikeClient`/`run_spike.py` verbatim — only the patch step is new.

### A.4 If Q6 passes — productionizing the patch (note for the real project, not the spike)
Don't ship a CI `sed`. Fork grpc-swift, apply the one-liner on a branch, and pin by revision:
```swift
.package(url: "https://github.com/brianm998/grpc-swift.git", revision: "<sha-of-ucrt-fix>")
```
File the upstream PR in parallel (`#elseif canImport(ucrt) / public import ucrt` in `RetryDelaySequence.swift`);
when it lands in 2.2.4+, drop the fork. **Do not block** the daemon on the upstream merge — the pinned fork is
deterministic.

---

## Part B — Q7: protobuf over stdio (the NIO-free transport)

This validates the recommended default transport from the (revised) design: length-framed protobuf
`Envelope`s over the daemon's stdin/stdout. The Windows-specific risk being tested is **binary integrity over
Windows stdio**: by default Windows opens stdio in *text mode*, which translates `\n`↔`\r\n` and treats
`0x1A` as EOF — that corrupts binary protobuf. The fix is `_setmode(_O_BINARY)`; this test proves it works.

### B.1 Extend `proto/spike.proto`
Append the transport envelope (reuse the existing `EchoRequest`/`EchoResponse` as payloads):
```proto
message Envelope {
  uint64 id = 1;                 // correlate request <-> response / stream items
  enum Kind {
    REQUEST     = 0;
    RESPONSE    = 1;
    ERROR       = 2;
    STREAM_ITEM = 3;
    STREAM_END  = 4;
    NOTIFICATION = 5;
  }
  Kind   kind    = 2;
  string method  = 3;            // "echo" | "stream" | "shutdown"
  bytes  payload = 4;            // a serialized EchoRequest / EchoResponse
  string error   = 5;
}
```
Regenerate the **Swift** stubs (with `Visibility=Public`, using the plugin built from the resolved checkout —
exactly as SPIKE_FINDINGS.md describes) and commit the updated `spike.pb.swift`. The Python stub is generated
in CI (§B.4).

### B.2 New executable target — add to `Package.swift`
```swift
.executableTarget(
    name: "StdioEcho",
    dependencies: [
        "SpikeProto",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
    ]
),
```
Note: `StdioEcho` depends only on `SwiftProtobuf` (pure Swift, officially Windows-supported) — **not** on
`GRPCCore`/NIO. That independence is the point.

### B.3 `Sources/StdioEcho/main.swift`
```swift
import Foundation
import SpikeProto
import SwiftProtobuf
#if os(Windows)
import ucrt
#endif

// --- Windows binary stdio (no CRLF translation, no 0x1A=EOF) ---
func setBinaryStdIO() {
#if os(Windows)
    let O_BINARY: Int32 = 0x8000          // _O_BINARY
    _ = _setmode(_fileno(stdin),  O_BINARY)
    _ = _setmode(_fileno(stdout), O_BINARY)
#endif
}

let inHandle  = FileHandle.standardInput
let outHandle = FileHandle.standardOutput
func logErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// Read exactly n bytes; nil on EOF / short final frame.
func readExactly(_ n: Int) -> Data? {
    var buf = Data()
    while buf.count < n {
        let chunk = inHandle.readData(ofLength: n - buf.count)
        if chunk.isEmpty { return nil }   // EOF
        buf.append(chunk)
    }
    return buf
}

func readFrame() -> Data? {
    guard let len = readExactly(4) else { return nil }
    let n = len.reduce(0) { ($0 << 8) | Int($1) }   // 4-byte big-endian
    return readExactly(n)
}

func writeFrame(_ data: Data) {
    let n = UInt32(data.count).bigEndian
    var header = Data(count: 4)
    withUnsafeBytes(of: n) { header.replaceSubrange(0..<4, with: $0) }
    outHandle.write(header)
    outHandle.write(data)                 // FileHandle.write is unbuffered; no flush needed
}

func envelope(id: UInt64, kind: Spike_V1_Envelope.Kind,
              payload: Data = Data(), error: String = "") -> Data {
    var e = Spike_V1_Envelope()
    e.id = id; e.kind = kind; e.payload = payload; e.error = error
    return (try? e.serializedData()) ?? Data()
}

setBinaryStdIO()
logErr("StdioEcho up (pid \(ProcessInfo.processInfo.processIdentifier))")

while let frame = readFrame() {
    guard let env = try? Spike_V1_Envelope(serializedData: frame) else { logErr("bad envelope"); continue }
    let req = try? Spike_V1_EchoRequest(serializedData: env.payload)
    switch env.method {
    case "echo":
        var r = Spike_V1_EchoResponse(); r.message = "echo: \(req?.message ?? "")"; r.index = 0
        writeFrame(envelope(id: env.id, kind: .response, payload: (try? r.serializedData()) ?? Data()))
    case "stream":
        let count = max(1, Int(req?.count ?? 1))
        for i in 0..<count {
            var item = Spike_V1_EchoResponse(); item.message = "echo: \(req?.message ?? "")"; item.index = Int32(i)
            writeFrame(envelope(id: env.id, kind: .streamItem, payload: (try? item.serializedData()) ?? Data()))
        }
        writeFrame(envelope(id: env.id, kind: .streamEnd))
    case "shutdown":
        logErr("shutdown requested"); exit(0)
    default:
        writeFrame(envelope(id: env.id, kind: .error, error: "unknown method \(env.method)"))
    }
}
logErr("stdin closed, exiting")
```

### B.4 `scripts/run_stdio_spike.py` (cross-platform harness; same role as `run_spike.py`)
```python
#!/usr/bin/env python3
import struct, subprocess, sys, os
import spike_pb2 as pb     # generated in CI by protoc --python_out

exe = ".exe" if os.name == "nt" else ""
server_bin = os.path.join(".build", "debug", "StdioEcho" + exe)
print(f"server={server_bin}", flush=True)

# Binary pipes (Python PIPEs are binary by default); stderr inherits so we see the server's logs.
p = subprocess.Popen([server_bin], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

def send(env):
    data = env.SerializeToString()
    p.stdin.write(struct.pack(">I", len(data)) + data); p.stdin.flush()

def recv():
    hdr = p.stdout.read(4)
    if len(hdr) < 4: return None
    (n,) = struct.unpack(">I", hdr)
    body = b""
    while len(body) < n:
        chunk = p.stdout.read(n - len(body))
        if not chunk: return None
        body += chunk
    e = pb.Envelope(); e.ParseFromString(body); return e

# Q7a: unary
req = pb.EchoRequest(message="hello", count=1)
send(pb.Envelope(id=1, kind=pb.Envelope.REQUEST, method="echo", payload=req.SerializeToString()))
r = recv()
if r is None or r.kind != pb.Envelope.RESPONSE: print("FAIL: no RESPONSE (Q7 unary)"); p.kill(); sys.exit(20)
resp = pb.EchoResponse(); resp.ParseFromString(r.payload)
if resp.message != "echo: hello": print(f"FAIL: unary mismatch '{resp.message}'"); p.kill(); sys.exit(21)
print("STDIO_UNARY_OK", resp.message, flush=True)

# Q7b: server-streaming
send(pb.Envelope(id=2, kind=pb.Envelope.REQUEST, method="stream",
                 payload=pb.EchoRequest(message="stream", count=5).SerializeToString()))
items = 0
while True:
    e = recv()
    if e is None: print("FAIL: stream truncated (Q7 streaming)"); p.kill(); sys.exit(22)
    if e.kind == pb.Envelope.STREAM_ITEM: items += 1
    elif e.kind == pb.Envelope.STREAM_END: break
if items != 5: print(f"FAIL: stream items {items} != 5"); p.kill(); sys.exit(23)
print("STDIO_STREAM_OK", items, flush=True)

send(pb.Envelope(id=3, kind=pb.Envelope.REQUEST, method="shutdown"))
p.stdin.close()
try: p.wait(timeout=10)
except Exception: p.kill()
print("STDIO_ALL_OK")
```

### B.5 What this proves (and a representativeness note)
- It exercises the **Swift side's binary stdio on Windows** — the only real Windows risk for this transport —
  with both a unary round-trip and a multi-message stream, asserting byte integrity through the protobuf parse.
- The driver is **Python**, not the JVM. That's deliberate for spike cost: the framing/binary-mode behavior
  under test is entirely Swift-side and client-agnostic, and Python pipes are binary-clean on Windows.
  JVM `Process` stdin/stdout I/O on Windows is well-trodden and low-risk; the real implementation should still
  add a quick Kotlin smoke test, but it is **not** needed to answer Q7. (Optional stretch goal: add a tiny
  Kotlin/Gradle parent that spawns `StdioEcho` and runs the same two exchanges.)

---

## C — `.github/workflows/spike2.yml`

```yaml
name: spike round 2 (patched grpc + stdio)

on: { push: {}, workflow_dispatch: {} }

jobs:
  grpc-patched:
    name: "Q6 patched-grpc (${{ matrix.os }})"
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-15, windows-2022]
    steps:
      - uses: actions/checkout@v4
      - uses: SwiftyLab/setup-swift@latest
        with: { swift-version: "6.1.0" }
      - run: swift --version
      - name: Resolve
        run: swift package resolve
      - name: Patch grpc-swift ucrt import
        run: python scripts/patch_grpc_ucrt.py
      - name: Build
        run: swift build -v
      - name: Run two-process spike
        run: python scripts/run_spike.py

  stdio:
    name: "Q7 protobuf-over-stdio (${{ matrix.os }})"
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-15, windows-2022]
    steps:
      - uses: actions/checkout@v4
      - uses: SwiftyLab/setup-swift@latest
        with: { swift-version: "6.1.0" }
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - uses: arduino/setup-protoc@v3
        with: { version: "27.x" }
      - name: Install python protobuf runtime
        run: python -m pip install "protobuf>=5.27,<6"
      - name: Generate python protobuf stub
        run: protoc --proto_path=proto --python_out=scripts proto/spike.proto   # -> scripts/spike_pb2.py
      - name: Build StdioEcho
        run: swift build -v --product StdioEcho
      - name: Run stdio spike
        run: python scripts/run_stdio_spike.py
```

CI notes:
- The `stdio` job needs **no** gRPC at all — `StdioEcho` pulls only `SwiftProtobuf`. If grpc-swift weren't even
  in the package, this job would still pass; that independence is the safety property we're buying.
- Keep `protobuf` (python) and `protoc` versions compatible. Pin if the runner's default drifts.
- If `swift build --product StdioEcho` still compiles the gRPC targets (SwiftPM sometimes builds the whole
  graph), and that fails on Windows pre-patch, either run the `patch_grpc_ucrt.py` step here too, or split
  `StdioEcho` into its own minimal package with no grpc dependency to keep Q7 fully isolated. **Recommended:
  isolate it** — a `stdio-spike/` sub-package depending only on swift-protobuf removes all doubt.

---

## D — Updated results matrix (append to SPIKE_FINDINGS.md)

| Question | ubuntu | macos-15 | windows-2022 | Notes |
|---|---|---|---|---|
| Q6 patched-grpc build | ☐ | ☐ | ☐ | does the one-line ucrt fix make it compile? |
| Q6 patched-grpc unary+stream+handshake run | ☐ | ☐ | ☐ | **the unanswered question from round 1** |
| Q7 stdio build (`StdioEcho`) | ☐ | ☐ | ☐ | SwiftProtobuf only, no NIO |
| Q7 stdio unary | ☐ | ☐ | ☐ | binary stdio integrity |
| Q7 stdio streaming | ☐ | ☐ | ☐ | multi-message frame stream |

Also report: did `setBinaryStdIO()` prove necessary on Windows (try removing it and watch Q7 fail)? That
confirms the gotcha for the real implementation.

---

## E — Decision guidance (feeds the design doc's transport choice)

| Q6 (patched gRPC runs on Win) | Q7 (stdio runs on Win) | Conclusion |
|---|---|---|
| ✅ | ✅ | Both viable. **Recommend protobuf-over-stdio** anyway (no fork to maintain, no NIO-net dependency, simplest lifecycle). Keep patched-gRPC fork as a documented alternative. |
| ❌ (build) | ✅ | The ucrt fix wasn't enough / other Win issues. Go **stdio**. |
| ❌ (runtime, NIO net) | ✅ | NIO networking is the problem → **all socket transports suspect** → **stdio is the answer** (it dodges NIO net). |
| ✅ | ❌ | Unexpected — debug `_setmode`/framing first; if truly unfixable, use patched-gRPC fork. |
| ❌ | ❌ | Deeper Swift-on-Windows trouble; escalate — revisit CLI-subprocess or macOS/Linux-only scope from the original analysis. |

The most likely outcome is the **top row** (both work), which still points at protobuf-over-stdio as the
default for the reasons above — but Q6 passing is valuable insurance and confirms NIO networking is healthy on
Windows should we ever want sockets.

---

## F — When done

1. Fill the matrix (§D) and paste it + the CI run links back to the requester.
2. For any `❌`, include the failing log excerpt and your diagnosis.
3. State the chosen transport per §E.
4. Hand back the validated artifacts to fold into the main project's `daemon/` Phase 0:
   - working `Package.swift` version pins (+ fork revision if gRPC),
   - the `setBinaryStdIO()` snippet and framing helpers if stdio,
   - the `Envelope` proto.
5. This repo stays throwaway — archive it after the matrix is filled.
