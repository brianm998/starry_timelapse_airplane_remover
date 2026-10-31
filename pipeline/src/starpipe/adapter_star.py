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
    parser: str = "exit"  # exit | xctest | gradle
    heavy: bool = True
    ui: bool = False  # keep the display awake (caffeinate -d -u)
    results_glob: str | None = None  # gradle JUnit XML directory, relative to cwd
    env: tuple[tuple[str, str], ...] = ()  # extra environment; values may use {root}
    expect: int | None = None  # exactly this many tests must have executed (a partial run is not green)


def _swift_build(pkg: str, *extra: str) -> CheckSpec:
    return CheckSpec(f"build:{pkg}", f"swift build {pkg}", ("swift", "build", "--package-path", pkg, *extra))


def _swift_test(pkg: str, *extra: str, tid: str | None = None) -> CheckSpec:
    return CheckSpec(
        f"test:{tid or pkg}", f"swift test {pkg}",
        ("swift", "test", "--package-path", pkg, *extra), parser="xctest",
    )


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
             "-derivedDataPath", GUI_DD, "CODE_SIGNING_ALLOWED=NO", "build"),
        ),
        CheckSpec(
            "build:desktop", "gradle compile star-desktop",
            ("./gradlew", "compileKotlin", "compileTestKotlin", "--no-daemon"), cwd="star-desktop",
        ),
        _swift_test("logging"),
        _swift_build("pipeline/monitor"),
        _swift_test("pipeline/monitor"),
        _swift_test("StarCpp", "--filter", "StarCppBridgeTests", tid="StarCpp"),
        _swift_test("StarCpp", "--filter", "StarCppWGPUTests", tid="StarCpp-wgpu"),
        _swift_test("StarCore"),
        _swift_test("cli", "--skip", "GherkinTests"),
        _swift_test("daemon"),
        _swift_test("trail_tools"),
        _swift_test("decision_tree_generator"),
        CheckSpec(
            "test:gui", "xcodebuild test gui starTests",
            ("xcodebuild", "-project", "gui/star.xcodeproj", "-scheme", "star", "-configuration", "Debug",
             "-derivedDataPath", GUI_DD, "CODE_SIGNING_ALLOWED=NO", "-only-testing:starTests", "test"),
            parser="xctest", ui=True,
        ),
        CheckSpec(
            "test:desktop", "gradle test star-desktop",
            ("./gradlew", "test", "--no-daemon"), cwd="star-desktop", parser="gradle",
            results_glob="build/test-results/test",
        ),
        CheckSpec(
            "test:pipeline", "pytest pipeline",
            ("uv", "run", "--project", "pipeline", "pytest", "-q"), parser="pytest", heavy=False,
        ),
        CheckSpec(
            "t0:pipeline-static", "pyright + ruff pipeline",
            ("bash", "-c", PIPELINE_STATIC),
            heavy=False,
        ),
        CheckSpec("t0:diff-check", "git diff --check", ("git", "diff", "--check", "{base}"), heavy=False),
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
