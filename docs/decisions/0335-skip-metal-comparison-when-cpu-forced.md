# 0335: skip Metal-comparison wgpu tests when the CPU merge is forced

Under `STAR_USE_GPU_FOR_MERGE=0`, `ImageAligner` runs the CPU path even for `useGPU: true`, so
`testAlignedMergeMatchesTheMetalKernelClosely` held wgpu to 0.05% against a CPU result and failed.
The warp, aligned-merge and median-merge Metal comparisons now `XCTSkipIf(GPUCapability.mergeForcedOff())`.
Thresholds are unchanged, no production code changed, and the CPU-comparison tests are untouched.
