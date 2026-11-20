# 0701: narrow heavy suites in the test step, run whole once at landing

Decision: a task's test step runs only the tests its change reaches. Each suite's whole run happens once, where
something already runs it: pr-gate (`whole_later = "ci"`) or the local batch tier (`whole_later = "batch"`).

- pr-gate covers test-StarCore (pr-gate.yml:255, :332), test-daemon (:258), test-pipeline (:163) and test-desktop (:204).
- pr-gate has no xcodebuild and no StarCpp or cli tests, so test-gui, test-StarCpp and test-cli are added to the
  `batch` tier in `.mason/landing.toml`. test-gui's old comment ("pr-gate's macOS job covers it") was wrong and is fixed.
- `narrow_smoke` names the whole-tree guards that run on every change when narrowing falls back (#669 ran 384 gui and
  820 desktop tests for an icon): gui `NoHardCodedStringsTests`, `IdRegistryTests`; desktop `NoHardCodedStringsTest`,
  `IdRegistryTest`, `StarArtTest`; StarCore `LocalizationTests`, `ConfigRoundTripTests`, `ArtifactInputsTests`.
- The narrowed StarCore and daemon commands are plain `swift test --parallel --xunit-output` with the CPU-merge key, not
  `shards.py`: sharding is for the whole run, and a filtered run is small.
- Unchanged: test-StarCpp-qos, test-gherkin, test-StarCpp-wgpu. Kept: the batch tier's test-desktop (owner's call).
- Unverified: the installed MASON runtime predates `whole_later` and `narrow_smoke` and its `definition check`
  accepts the file without reading them; the desktop smoke names use the fully qualified class as `narrow_each` expects.
