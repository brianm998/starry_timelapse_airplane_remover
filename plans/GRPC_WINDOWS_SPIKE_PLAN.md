# Spike: Validate grpc-swift on Windows (and Linux/macOS) via GitHub Actions

**Status:** Handoff spec for a de-risking spike.
**Audience:** An agent/engineer who will create a **separate, throwaway git repo** and use GitHub Actions to
prove (or disprove) that the gRPC transport chosen in `CROSS_PLATFORM_DAEMON_DESIGN.md` actually works on
Windows. The requester has no Windows machine — **all testing must run in CI.**

---

## 0. Why this spike exists

The cross-platform Star plan (`CROSS_PLATFORM_DAEMON_DESIGN.md`, §13 Risk #1) hinges on a single unverified
assumption: that a **grpc-swift 2** server can build and run on **Windows** with the same Swift toolchain that
already builds StarCore there. grpc-swift is well supported on macOS/Linux; Windows is the unknown. If Windows
gRPC doesn't work, the whole "headless Swift daemon + gRPC" approach needs a fallback (custom
length-prefixed-protobuf-over-TCP, or shipping the daemon only on macOS/Linux). **We must know this before
building anything real.**

This spike is intentionally **separate from the main repo**: it pulls in no StarCore/OpenCV/Swift-package
weight, so a failure points unambiguously at gRPC-on-Windows, not at our codebase.

---

## 1. Questions the spike must answer (each is pass/fail per OS)

| # | Question | How it's tested |
|---|---|---|
| Q1 | Does the grpc-swift 2 dependency graph **resolve and compile** on Windows? | `swift build` job |
| Q2 | Can a server **bind** an ephemeral loopback port and a client complete a **unary** RPC? | two-process run |
| Q3 | Does a **server-streaming** RPC work? (Star streams progress — this is not optional) | two-process run |
| Q4 | Does the **stdout port-handshake** pattern (`stard` prints `{listening,port}`, client reads it) work on Windows? | run harness |
| Q5 | *(secondary)* Does **protobuf + grpc codegen** (`protoc` plugins / SwiftPM build plugin) work on Windows? | optional codegen job |

Run the **same** tests on `macos` and `ubuntu` in one matrix. Linux/macOS passing while Windows fails isolates
the problem; all three passing is the green light.

> Q1–Q4 are the gate. Q5 is a separate, lower-stakes risk — we can always pre-generate stubs on macOS/Linux and
> commit them — so the spike **commits pre-generated stubs** to keep Q1–Q4 independent of codegen, and tests Q5
> in an isolated, allowed-to-fail job.

---

## 2. Deliverable

A new public (or private) GitHub repo, e.g. `grpc-swift-windows-spike`, containing the files below, with a
green (or instructively red) Actions run. The agent reports back:
1. The **filled-in results matrix** (§7).
2. Links to the CI run(s).
3. For any failure: the relevant log excerpt and the agent's diagnosis + suggested fallback.
4. The **resolved versions** (`Package.resolved`) — so we know exactly which grpc-swift/NIO versions passed.

---

## 3. Repo layout

```
grpc-swift-windows-spike/
  Package.swift
  proto/
    spike.proto
  Sources/
    SpikeProto/
      spike.pb.swift          # generated, COMMITTED (see §5)
      spike.grpc.swift        # generated, COMMITTED
    SpikeServer/
      main.swift
    SpikeClient/
      main.swift
  Tests/
    SpikeTests/
      InProcessTests.swift    # secondary: in-process server+client (fast sanity)
  scripts/
    run_spike.py              # cross-platform: spawn server, read handshake, run client, assert
    generate.sh               # regenerate stubs on macOS/Linux (dev-only, not run in CI gate)
  .github/workflows/
    spike.yml
  README.md                   # paste §1 + §7 so results live with the repo
```

---

## 4. Source files

> **API caveat for the implementing agent:** grpc-swift 2's generated API and server/transport constructors
> have shifted across 2.x releases. The code below is written against the grpc-swift 2 GA shape but **treat it
> as a starting point** — after `swift package resolve`, open the generated `spike.grpc.swift` and the
> `GRPCNIOTransportHTTP2` module and align names (e.g. the generated service protocol, the
> `HTTP2ServerTransport.Posix` initializer, and how the bound address is read). Getting it to compile is part
> of answering Q1. Pin exact versions in `Package.swift` once a working set is found, and commit
> `Package.resolved`.

### `proto/spike.proto`
```proto
syntax = "proto3";
package spike.v1;

service Echo {
  // Q2: unary round-trip
  rpc UnaryEcho(EchoRequest) returns (EchoResponse);
  // Q3: server-streaming (mirrors Star's progress stream)
  rpc StreamEcho(EchoRequest) returns (stream EchoResponse);
}

message EchoRequest  { string message = 1; int32 count = 2; }
message EchoResponse { string message = 1; int32 index = 2; }
```

### `Package.swift`
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrpcWindowsSpike",
    platforms: [.macOS(.v15)],   // ignored on Windows/Linux; grpc-swift 2 needs macOS 15 when on mac
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git",               from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git",      from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git",          from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "SpikeProto",
            dependencies: [
                .product(name: "GRPCCore",     package: "grpc-swift"),
                .product(name: "GRPCProtobuf",  package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "SpikeServer",
            dependencies: [
                "SpikeProto",
                .product(name: "GRPCCore",              package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2",  package: "grpc-swift-nio-transport"),
            ]
        ),
        .executableTarget(
            name: "SpikeClient",
            dependencies: [
                "SpikeProto",
                .product(name: "GRPCCore",              package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2",  package: "grpc-swift-nio-transport"),
            ]
        ),
        .testTarget(
            name: "SpikeTests",
            dependencies: [
                "SpikeProto",
                .product(name: "GRPCCore",              package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2",  package: "grpc-swift-nio-transport"),
            ]
        ),
    ]
)
```

### `Sources/SpikeServer/main.swift`
```swift
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SpikeProto

// Implements the generated service protocol. The exact protocol name comes from spike.grpc.swift
// (likely `Spike_V1_Echo.SimpleServiceProtocol`). Adjust to match.
struct EchoService: Spike_V1_Echo.SimpleServiceProtocol {
    func unaryEcho(
        request: Spike_V1_EchoRequest,
        context: ServerContext
    ) async throws -> Spike_V1_EchoResponse {
        .with { $0.message = "echo: \(request.message)"; $0.index = 0 }
    }

    func streamEcho(
        request: Spike_V1_EchoRequest,
        response: RPCWriter<Spike_V1_EchoResponse>,
        context: ServerContext
    ) async throws {
        let n = max(1, request.count)
        for i in 0..<n {
            try await response.write(.with { $0.message = "echo: \(request.message)"; $0.index = i })
        }
    }
}

@main
struct Server {
    static func main() async throws {
        // Bind ephemeral loopback port (port 0 -> OS picks).
        let transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: 0),
            transportSecurity: .plaintext
        )
        let server = GRPCServer(transport: transport, services: [EchoService()])

        // Serve in the background, then announce the bound port on stdout (the handshake Q4 tests).
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }

            // Read the actual bound address once the listener is up.
            if let address = try await transport.listeningAddress,
               let port = address.ipv4?.port {
                let line = #"{"event":"listening","port":\#(port),"pid":\#(getpid())}"#
                print(line)
                FileHandle.standardOutput.synchronizeFile()  // ensure the line is flushed for the harness
                fflush(stdout)
            } else {
                FileHandle.standardError.write(Data("failed to get listening address\n".utf8))
                exit(2)
            }
            try await group.next()
        }
    }
}
```
> If `transport.listeningAddress` / `address.ipv4?.port` don't exist under the resolved version, find the
> equivalent (grpc-swift 2 exposes the resolved listening address on the NIO transport). This is part of Q1.

### `Sources/SpikeClient/main.swift`
```swift
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SpikeProto

@main
struct Client {
    static func main() async throws {
        // Port passed as argv[1] by the harness.
        guard CommandLine.arguments.count > 1, let port = Int(CommandLine.arguments[1]) else {
            FileHandle.standardError.write(Data("usage: SpikeClient <port>\n".utf8)); exit(64)
        }

        try await withGRPCClient(
            transport: try .http2NIOPosix(
                target: .ipv4(host: "127.0.0.1", port: port),
                transportSecurity: .plaintext
            )
        ) { client in
            let echo = Spike_V1_Echo.Client(wrapping: client)

            // Q2: unary
            let resp = try await echo.unaryEcho(.with { $0.message = "hello"; $0.count = 1 })
            guard resp.message == "echo: hello" else {
                FileHandle.standardError.write(Data("unary mismatch: \(resp.message)\n".utf8)); exit(3)
            }
            print("UNARY_OK \(resp.message)")

            // Q3: server-streaming
            var received = 0
            try await echo.streamEcho(.with { $0.message = "stream"; $0.count = 5 }) { stream in
                for try await msg in stream.messages { received += 1; _ = msg }
            }
            guard received == 5 else {
                FileHandle.standardError.write(Data("stream count \(received) != 5\n".utf8)); exit(4)
            }
            print("STREAM_OK \(received)")
        }
        print("CLIENT_DONE")
    }
}
```

### `Tests/SpikeTests/InProcessTests.swift` (secondary, fast)
```swift
import XCTest
import GRPCCore
import GRPCNIOTransportHTTP2
import SpikeProto
@testable import SpikeProto

final class InProcessTests: XCTestCase {
    func testUnaryAndStreamInProcess() async throws {
        // Start an in-process server on an ephemeral port and run a client against it.
        // Mirrors main.swift logic; proves build+run without a second process.
        // (Implementation left to the agent; keep it small. This is a sanity check, not the gate.)
    }
}
```

### `scripts/run_spike.py` (the cross-platform harness — identical on all 3 OSes)
```python
#!/usr/bin/env python3
import json, subprocess, sys, time, os, signal, threading

# Locate built binaries (Windows adds .exe).
exe = ".exe" if os.name == "nt" else ""
build_dir = os.path.join(".build", "debug")
server_bin = os.path.join(build_dir, "SpikeServer" + exe)
client_bin = os.path.join(build_dir, "SpikeClient" + exe)

print(f"server={server_bin} client={client_bin}", flush=True)

# Launch server, capture stdout, find the handshake line.
server = subprocess.Popen([server_bin], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, bufsize=1)

port = None
deadline = time.time() + 60
def read_lines():
    global port
    for line in server.stdout:
        sys.stdout.write("[server] " + line); sys.stdout.flush()
        line = line.strip()
        if line.startswith("{") and '"event"' in line and '"listening"' in line:
            try:
                port = json.loads(line)["port"]
            except Exception as e:
                print("handshake parse error:", e)

t = threading.Thread(target=read_lines, daemon=True); t.start()
while port is None and time.time() < deadline and server.poll() is None:
    time.sleep(0.2)

if port is None:
    print("FAIL: never received listening handshake (Q4)"); server.kill(); sys.exit(10)
print(f"HANDSHAKE_OK port={port} (Q4 pass)", flush=True)

# Run the client against the discovered port.
res = subprocess.run([client_bin, str(port)], text=True, capture_output=True, timeout=60)
sys.stdout.write(res.stdout); sys.stderr.write(res.stderr)

server.terminate()
try: server.wait(timeout=10)
except Exception: server.kill()

if res.returncode != 0:
    print(f"FAIL: client exit {res.returncode} (Q2/Q3)"); sys.exit(res.returncode)
if "UNARY_OK" not in res.stdout: print("FAIL: no UNARY_OK (Q2)"); sys.exit(11)
if "STREAM_OK" not in res.stdout: print("FAIL: no STREAM_OK (Q3)"); sys.exit(12)
print("ALL_OK: Q2+Q3+Q4 passed")
```

### `scripts/generate.sh` (dev-only; run on macOS/Linux to (re)generate the committed stubs)
```bash
#!/usr/bin/env bash
set -euo pipefail
# Requires protoc + the swift plugins. Build the plugins from the resolved packages, or install:
#   brew install protobuf swift-protobuf            # protoc-gen-swift
# and build protoc-gen-grpc-swift from grpc-swift-protobuf.
protoc \
  --proto_path=proto \
  --swift_out=Sources/SpikeProto \
  --grpc-swift_out=Sources/SpikeProto \
  proto/spike.proto
echo "Generated stubs into Sources/SpikeProto — commit them."
```

---

## 5. Stub generation policy (keeps Q1–Q4 independent of Q5)

1. On a **macOS or Linux** dev box, run `scripts/generate.sh`, producing `spike.pb.swift` + `spike.grpc.swift`.
2. **Commit those generated files.** CI does *not* regenerate them for the main gate — it builds the committed
   stubs. This way a Windows failure means "grpc-swift runtime doesn't work on Windows," not "codegen is
   broken on Windows" (a separate, less critical risk).
3. Q5 (codegen on Windows) is tested in its own `continue-on-error` job (§6) so it informs but never blocks.

---

## 6. `.github/workflows/spike.yml`

```yaml
name: grpc-swift cross-platform spike

on: { push: {}, workflow_dispatch: {} }

jobs:
  build-and-run:
    name: "build+run (${{ matrix.os }})"
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false          # we WANT to see all three results even if one fails
      matrix:
        os: [ubuntu-latest, macos-14, windows-latest]
    steps:
      - uses: actions/checkout@v4

      # Uniform Swift setup across all three OSes. SwiftyLab/setup-swift supports Windows+macOS+Linux.
      # Fallback for Windows specifically: compnerd/gha-setup-swift@main (branch: swift-6.0-release, tag: 6.0).
      - name: Set up Swift
        uses: SwiftyLab/setup-swift@latest
        with:
          swift-version: "6.0.0"

      - name: Swift version
        run: swift --version

      # Windows gotcha: the Swift compiler needs the MSVC toolchain on PATH. The setup action usually
      # handles this; if linking fails, uncomment the VS dev-cmd step below.
      # - name: Set up MSVC (windows only)
      #   if: runner.os == 'Windows'
      #   uses: ilammy/msvc-dev-cmd@v1

      - name: Resolve
        run: swift package resolve

      - name: Upload Package.resolved
        uses: actions/upload-artifact@v4
        with: { name: "resolved-${{ matrix.os }}", path: Package.resolved }

      # Q1: does it compile on this OS?
      - name: Build
        run: swift build -v

      # Secondary sanity: in-process test (also part of Q1/Q2/Q3 coverage).
      - name: Test (in-process)
        run: swift test
        continue-on-error: true   # the two-process harness below is the real gate

      - name: Set up Python
        uses: actions/setup-python@v5
        with: { python-version: "3.12" }

      # Q2 + Q3 + Q4: two real processes, loopback, handshake, unary + streaming.
      - name: Run two-process spike
        run: python scripts/run_spike.py

  codegen-windows:
    name: "Q5: codegen on Windows (informational)"
    runs-on: windows-latest
    continue-on-error: true        # never blocks; just tells us if Windows codegen is viable
    steps:
      - uses: actions/checkout@v4
      - uses: SwiftyLab/setup-swift@latest
        with: { swift-version: "6.0.0" }
      - name: Install protoc
        uses: arduino/setup-protoc@v3
        with: { version: "27.x" }
      # Build the swift protoc plugins from the resolved packages, then run protoc, then build.
      # If the SwiftPM build-plugin route is preferred, switch SpikeProto to use the
      # GRPCProtobufGenerator build plugin and just `swift build` here instead.
      - name: Generate stubs on Windows
        run: bash scripts/generate.sh
      - name: Build with freshly generated stubs
        run: swift build -v
```

### CI notes for the implementing agent
- **`fail-fast: false`** is deliberate — the whole point is the per-OS matrix result, not a single red X.
- **Swift on Windows runners** is not preinstalled; the setup action provides it. If `SwiftyLab/setup-swift`
  misbehaves on Windows, swap in `compnerd/gha-setup-swift@main` for the windows leg
  (`with: { branch: swift-6.0-release, tag: 6.0 }`). Document which one worked.
- **Linker/MSVC errors on Windows** are the most likely first failure. Try the commented `msvc-dev-cmd` step.
- **Shell uniformity:** the Python harness avoids PowerShell-vs-bash differences. Keep run steps in Python or
  plain `run:` (Actions defaults to `pwsh` on Windows, `bash` elsewhere — the steps above are single commands
  that work in both).
- **Timeouts:** the harness has 60s deadlines; bump if Windows cold-start is slow.

---

## 7. Results matrix to report back

Fill this in and return it (also paste into the spike repo's `README.md`):

| Question | ubuntu | macos | windows | Notes / log link |
|---|---|---|---|---|
| Q1 build (`swift build`) | ☐ | ☐ | ☐ | |
| Q2 unary RPC | ☐ | ☐ | ☐ | |
| Q3 server-streaming RPC | ☐ | ☐ | ☐ | |
| Q4 stdout handshake + 2-process | ☐ | ☐ | ☐ | |
| Q5 codegen on Windows (info) | n/a | n/a | ☐ | allowed to fail |

Also report: resolved grpc-swift / grpc-swift-nio-transport / swift-protobuf versions; which Swift setup action
worked on Windows; and any code changes needed to make `main.swift` compile against the resolved API.

---

## 8. Interpreting the outcome (decision for the main project)

- **All of Q1–Q4 green on Windows** → grpc-swift transport is validated; proceed with
  `CROSS_PLATFORM_DAEMON_DESIGN.md` as written. Record the working versions and pin them.
- **Q1 fails on Windows** (won't build) → grpc-swift not viable on Windows now. Fallbacks, in order:
  1. **Custom framing:** length-prefixed protobuf messages over a raw swift-nio TCP server (swift-nio itself is
     the next thing to spike on Windows — much smaller surface than grpc-swift). The proto messages from the
     design doc are reused; only the transport changes.
  2. **Ship the daemon on macOS/Linux only**, defer Windows.
  3. Reconsider the CLI-subprocess or C++-core approaches from the earlier analysis.
- **Q1/Q2 pass but Q3 (streaming) fails** → progress streaming would need polling instead of streaming; note it
  but it's a minor design change, not a blocker.
- **Q4 fails only** → handshake/process-spawn issue, not a gRPC issue; adjust the launch mechanism (e.g. write
  the port to a file the client polls instead of stdout).
- **Q5 fails** (codegen on Windows) → fine; generate stubs in CI on Linux/macOS and commit/vendor them. Not a
  blocker for the daemon.

This spike is **throwaway**: once it answers the matrix, archive the repo and copy the working
`Package.swift` version pins + the validated `main.swift` transport snippet back into the main project's
`daemon/` (Phase 0/1 of the design doc).
