"""Everything that is specific to star: the impact map, artifact links, heavy-command patterns.

Nothing else in starpipe may name a star path or tool. Per-machine facts (slot counts, timings)
live in config.toml, not here.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

# star-desktop needs a JDK 21 (sourceCompatibility 21); a launchd agent has no JAVA_HOME, and the system `java` shim picks
# an older JDK. Used when neither config.java_home nor the environment names one.
JAVA_HOME_CANDIDATES = ["/Applications/Android Studio.app/Contents/jbr/Contents/Home"]
OWNER = "brianm998"
REPO = "starry_timelapse_airplane_remover"

# Gitignored build artifacts a worktree gets by symlink from the main checkout
# (memory gui-worktree-build). A diff adding any of these is rejected by T0.
ARTIFACT_LINKS = [
    "opencv/include",
    "opencv/lib",
    "opencv/opencv2.framework",
    "StarDecisionTrees/include",
    "StarDecisionTrees/lib",
    "gui/videos",
    "external_binaries/bin",
]

# A Bash command that starts one of these is a heavy job (one at a time on this Mac).
HEAVY_PATTERN = re.compile(
    r"(?:^|[;&|(]|&&|\|\||\n)\s*(?:[\w./-]+/)?"
    r"(?:swift\s+(?:build|test|run)\b|xcodebuild\b|gradle\b|gradlew\b"
    r"|\.build/[\w-]+/(?:star|stard)\b|star-gherkin\b)"
)

# The nightly (plan §8.1 T4): every local suite, then the Gherkin features, against origin/develop's tip. Which features exist
# is read from the worktree being tested (gherkin/generated/*.json), so a new feature is picked up without touching this file.
def gherkin_test_name(feature: str) -> str:
    return "test" + feature[:1].upper() + feature[1:] + "Feature"


NIGHTLY_ENV = (("STAR_TEST_DATA", "{test_data}"), ("STAR_FFMPEG_DIR", "{root}/external_binaries/bin"),
               ("STAR_REMOVAL_REPORTS", "{build}/removal-reports"))


def nightly_setup() -> list[CheckSpec]:
    """Builds the Gherkin cli leg's Then steps shell out to."""
    return [
        CheckSpec("setup:removal_tools", "swift build removal_tools (release)",
                  ("swift", "build", "-c", "release", "--package-path", "removal_tools")),
        CheckSpec("setup:trail_tools", "swift build trail_tools (release)",
                  ("swift", "build", "-c", "release", "--package-path", "trail_tools")),
    ]


def nightly_gherkin_cli(root: Path, env: tuple[tuple[str, str], ...]) -> list[CheckSpec]:
    features: list[str] = json.loads((root / "gherkin/generated/features-cli.json").read_text())
    return [
        CheckSpec(
            f"gherkin:cli/{f}", f"gherkin cli: {f}",
            ("swift", "test", "-c", "release", "-Xswiftc", "-enable-testing", "--disable-swift-testing", "--package-path", "cli",
             "--filter", f"GherkinTests.GeneratedFeatureTests/{gherkin_test_name(f)}"),
            parser="xctest", expect=1, env=env,
        )
        for f in features
    ]


def nightly_gherkin_ui(root: Path, env: tuple[tuple[str, str], ...]) -> CheckSpec | None:
    """The mac gui's @ui features as one xcodebuild run under caffeinate (needs UI automation and the display)."""
    features = [f for f in json.loads((root / "gherkin/generated/features-mac-gui.json").read_text()) if f.startswith("ui")]
    if not features:
        return None
    only = tuple(f"-only-testing:starUITests/GeneratedFeatureUITests/{gherkin_test_name(f)}" for f in features)
    return CheckSpec(
        "gherkin:gui-ui", f"gherkin mac gui @ui ({len(features)} features)",
        ("xcodebuild", "test", "-project", "gui/star.xcodeproj", "-scheme", "star", "-configuration", "Release",
         "-derivedDataPath", "{build}/gui-ui-dd", "ENABLE_TESTABILITY=YES", *only,
         "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM="),
        parser="xctest", expect=len(features), ui=True, env=tuple((("TEST_RUNNER_" + k, v) for k, v in env)) + env,
    )


def nightly_local_checks() -> list[str]:
    """Every local test suite the impact map knows."""
    return [cid for cid in CHECKS if cid.startswith("test:")]


# Top-level directories that hold no source the impact map needs to know about.
IGNORED_TOP_LEVEL = {
    ".claude", ".git", ".github", "docs", "plans", "demo_videos", "test_data", "ffmpeg", "opencv",
    "wgpu", "external_binaries", "logging-objc", "StarDecisionTrees", "removal_tools", "blobber",
    "c++_test", "horizon_test_bench", "horizon_tester", "outlier_feature_data_classifier",
    "tile_classifier_tester", "tile_extractor", "tools", "emacs_load_swift.sh", "packaging",
}


@dataclass(frozen=True)
class CheckSpec:
    id: str
    title: str
    argv: tuple[str, ...]
    cwd: str = "."
    parser: str = "exit"  # exit | xctest | xunit | pytest | gradle
    heavy: bool = True
    ui: bool = False  # keep the display awake (caffeinate -d -u)
    results_glob: str | None = None  # gradle JUnit XML directory, relative to cwd
    env: tuple[tuple[str, str], ...] = ()  # extra environment; values may use {root}
    expect: int | None = None  # exactly this many tests must have executed (a partial run is not green)
    # parser="xunit": the xunit files swift test wrote ({log_dir} is the check's log directory); the counts are summed
    xunit: tuple[str, ...] = ()
    # The test classes skipped from the parallel run, run here as a second, serial `swift test --filter` pass (its own heavy job)
    serial_argv: tuple[str, ...] = ()


def _swift_build(pkg: str, *extra: str) -> CheckSpec:
    return CheckSpec(f"build:{pkg}", f"swift build {pkg}", ("swift", "build", "--package-path", pkg, *extra))


# xctest prints "Test Case ... started" through buffered stdio, and the check log is a file, so the lines reached it only when the
# process exited: a hung test (#209) left a log of build output and no name. `script` runs the command on a pty, which makes
# xctest line-buffer, and passes the command's exit code through (`--verbose` does not unbuffer anything). The \r, ^D and
# backspaces it adds are dropped or ignored by the parsers.
LIVE_LOG = ("script", "-q", "/dev/null")


# The swift test suites that run with `--parallel`, each with the test classes that must not share the machine with other
# tests (they measure time, QoS or the whole machine's memory, or write fixed paths): those run in the second, serial pass of
# the check. Found empirically (ticket #238, this iMac Pro, 8 workers, seconds inside the heavy lock):
#   StarCpp   803 -> 367, 254 tests, 0 failed: a few huge classes (CloudAwareMergeTests) and few tests, so it wins.
#   StarCore  not parallel: SwiftPM runs XCTest `--parallel` as one `xctest` process per test, and a launch costs ~1 s on this
#             machine whatever the worker count (MappingTests, 46 trivial tests: 9 s serial, 41-47 s with 2, 8 or 16 workers),
#             so 1,619 tests cannot beat the 380 s serial run; its heavy tests are multi-threaded already and ran 10x slower
#             beside each other (HorizonConsensusTests: 97 s serial, 88 s parallel).
#   daemon    not parallel, same launch floor (313 tests, 132 s serial), and BackgroundExtractionSessionTests hangs beside others.
# `--parallel --xunit-output` records no `<skipped>`: an XCTSkip reads as a pass (StarCpp's serial banner says 7 skipped, its
# xunit file 0), so an unexpected skip in a parallel suite goes unseen. A suite is added here only when it wins by that much.
SERIAL_CLASSES: dict[str, tuple[str, ...]] = {
    "test:StarCpp": ("OpenCVQoSTests",),  # measures QoS-dependent worker counts; skipped here, but never beside other tests
}


def swift_test(pkg: str, *extra: str, tid: str | None = None) -> CheckSpec:
    check_id = f"test:{tid or pkg}"
    if check_id not in SERIAL_CLASSES:
        return CheckSpec(check_id, f"swift test {pkg}", (*LIVE_LOG, "swift", "test", "--package-path", pkg, *extra), parser="xctest")
    # --parallel prints no per-bundle "Executed N tests" totals, so the verdict comes from the xunit files
    name = log_stem(check_id)
    serial = SERIAL_CLASSES[check_id]
    skips = tuple(arg for cls in serial for arg in ("--skip", cls))
    xml = "{log_dir}/" + name + ".xml"
    parallel = (*LIVE_LOG, "swift", "test", "--package-path", pkg, *extra, "--parallel", "--num-workers", "{workers}",
                "--xunit-output", xml, *skips)
    xml_serial = "{log_dir}/" + name + "-serial.xml"
    # one worker is still serial, and a non-parallel `swift test` writes no XCTest xunit file
    serial_argv = (*LIVE_LOG, "swift", "test", "--package-path", pkg, "--parallel", "--num-workers", "1", "--xunit-output", xml_serial,
                   *(arg for cls in serial for arg in ("--filter", cls))) if serial else ()
    files = (xml, xml.removesuffix(".xml") + "-swift-testing.xml")
    if serial:
        files += (xml_serial, xml_serial.removesuffix(".xml") + "-swift-testing.xml")
    return CheckSpec(check_id, f"swift test {pkg} (parallel)", parallel, parser="xunit", xunit=files, serial_argv=serial_argv)


def log_stem(check_id: str) -> str:
    """A check id as a file name: `build:pipeline/monitor` must not become a nested path."""
    return check_id.replace(":", "_").replace("/", "_")


GUI_DD = "{build}/gui-dd"
PIPELINE_STATIC = (
    "uv run --project pipeline ruff check pipeline"
    " && uv run --project pipeline pyright --project pipeline/pyproject.toml"
)

CHECKS: dict[str, CheckSpec] = {
    c.id: c
    for c in [
        _swift_build("logging"),
        _swift_build("StarCpp"),
        _swift_build("StarCore"),
        _swift_build("cli"),
        _swift_build("daemon", "-c", "release"),
        _swift_build("trail_tools"),
        _swift_build("decision_tree_generator"),
        CheckSpec(
            "build:gui", "xcodebuild gui (scheme star)",
            ("xcodebuild", "-project", "gui/star.xcodeproj", "-scheme", "star", "-configuration", "Debug",
             "-derivedDataPath", GUI_DD, "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "build"),
        ),
        CheckSpec(
            "build:desktop", "gradle compile star-desktop",
            ("./gradlew", "compileKotlin", "compileTestKotlin", "--no-daemon"), cwd="star-desktop",
        ),
        swift_test("logging"),
        _swift_build("pipeline/monitor"),
        swift_test("pipeline/monitor"),
        swift_test("StarCpp", "--filter", "StarCppBridgeTests", tid="StarCpp"),
        swift_test("StarCpp", "--filter", "StarCppWGPUTests", tid="StarCpp-wgpu"),
        swift_test("StarCore"),
        swift_test("cli", "--skip", "GherkinTests"),
        swift_test("daemon"),
        swift_test("trail_tools"),
        swift_test("decision_tree_generator"),
        CheckSpec(
            "test:gui", "xcodebuild test gui starTests",
            ("xcodebuild", "-project", "gui/star.xcodeproj", "-scheme", "star", "-configuration", "Debug",
             "-derivedDataPath", GUI_DD, "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "-only-testing:starTests", "test"),
            parser="xctest", ui=True,
        ),
        CheckSpec(
            "test:desktop", "gradle test star-desktop",
            ("./gradlew", "test", "--no-daemon"), cwd="star-desktop", parser="gradle",
            results_glob="build/test-results/test",
        ),
        CheckSpec(
            "test:pipeline", "pytest pipeline",
            ("uv", "run", "pytest", "-q"), cwd="pipeline", parser="pytest", heavy=False,  # from pipeline/, so its pytest ini applies
        ),
        CheckSpec(
            "t0:pipeline-static", "pyright + ruff pipeline",
            ("bash", "-c", PIPELINE_STATIC),
            heavy=False,
        ),
        CheckSpec("t0:diff-check", "git diff --check", ("git", "diff", "--check", "{mergebase}"), heavy=False),
        CheckSpec(
            "t0:proto-sync", "gradle checkProtoSync",
            ("./gradlew", "checkProtoSync", "--no-daemon"), cwd="star-desktop",
        ),
        CheckSpec("t0:gherkin-generated", "gherkin/generate.sh output unchanged", ("gherkin/generate.sh",)),
    ]
}


@dataclass
class Rule:
    """Paths under any prefix select these builds and test targets."""

    prefixes: tuple[str, ...]
    builds: tuple[str, ...] = ()
    tests: tuple[str, ...] = ()
    note: str = ""
    # package changed -> its dependents are built too (see DEPENDENTS)
    package: str | None = None


# Build graph. A changed package builds itself and everything downstream, so an API break
# is caught; only the changed packages' own test targets run (D4, plan §8.1).
DEPENDENTS: dict[str, list[str]] = {
    "logging": ["StarCpp"],
    "StarCpp": ["StarCore"],
    "StarCore": ["cli", "daemon", "gui"],
    "cli": [],
    "daemon": [],
    "gui": [],
}

RULES: list[Rule] = [
    Rule(("logging/",), tests=("test:logging",), package="logging"),
    Rule(("StarCpp/",), tests=("test:StarCpp",), package="StarCpp"),
    Rule(("StarCore/Sources/StarCore/Resources/Localizations/",), tests=(), note="i18n: T0 checks it"),
    Rule(("StarCore/",), tests=("test:StarCore",), package="StarCore"),
    Rule(("cli/Tests/GherkinTests/",), note="gherkin runners: CI / nightly"),
    Rule(("cli/",), tests=("test:cli",), package="cli"),
    Rule(("gherkin/",), note="generated-files check (T0); features run when the plan names them"),
    Rule(("daemon/proto/",), builds=("build:daemon", "build:desktop"), tests=("test:daemon",), package="daemon"),
    Rule(("daemon/",), tests=("test:daemon",), package="daemon"),
    Rule(("gui/",), tests=("test:gui",), package="gui"),
    Rule(("star-desktop/",), builds=("build:desktop",), tests=("test:desktop",)),
    Rule(("trail_tools/",), builds=("build:trail_tools",), tests=("test:trail_tools",)),
    Rule(("decision_tree_generator/",), builds=("build:decision_tree_generator",),
         tests=("test:decision_tree_generator",)),
    Rule(("pipeline/monitor/",), builds=("build:pipeline/monitor",), tests=("test:pipeline/monitor",),
         note="swift build + test of the monitor"),
    Rule(("pipeline/",), tests=("test:pipeline",), note="pyright + ruff (T0)"),
]

# Paths that need no check at all.
NO_CHECK_PREFIXES = (".claude/", "docs/", "plans/", ".github/", "ffmpeg/", "opencv/", "wgpu/", "i18n/")
NO_CHECK_SUFFIXES = (".md",)


@dataclass
class T0Triggers:
    """Which T0 checks a set of paths turns on, besides the always-on diff check."""

    proto: bool = field(default=False)
    gherkin: bool = field(default=False)
    i18n: bool = field(default=False)
    pipeline: bool = field(default=False)


def worktree_name(root: Path) -> str:
    return root.name
