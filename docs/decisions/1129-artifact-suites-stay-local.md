# 1129 — Artifact-dependent suites stay on this Mac

## Problem
Task #1175. On node marmot `test-StarCore` failed compiling StarCpp (`opencv2/core.hpp` file not found): a node's
slot has no OpenCV or StarDecisionTrees, which `.mason/scripts/link-artifacts.sh` links from the main checkout.

## Decision (owner)
Keep these suites local for now: `remote = false` in `.mason/mason.toml`, pinned by a test. No marmot setup.

- Linked artifacts (build and test): StarCpp, StarCore, cli, daemon, trail_tools, decision_tree_generator
  (including `test-StarCpp-qos` and `test-StarCpp-wgpu`).
- Android Studio `JAVA_HOME`: `t0-proto-sync`, `build-desktop`, `test-desktop`.
- Signing identity: `build-gui`, `test-gui`.

Still placeable: `t0-diff-check`, `t0-i18n`, `t0-gherkin-generated`, `test-gherkin`, `build/test-logging`,
`build/test-monitor` (no linked artifact). The uv suites are tasks #1159/#1163, and judging exit 127 on a node as an
environment failure is already proposed (task #1165, a MASON change).

Not verified on the node: JAVA_HOME and the signing identity. They name paths and keys of this Mac, so those suites
stay local without a trial.

Applies once the definition is on `develop`.

## Undoing it
Provision the node (OpenCV, StarDecisionTrees, `external_binaries/bin`, link-artifacts in slot setup), then remove
the lines and update `pipeline/tests/test_mason_toml_nodes.py`.
