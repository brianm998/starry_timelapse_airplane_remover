# 0872: lossless intermediates are renamed to `.tif`, not re-encoded under the old name

Keeping the source extension and forcing TIFF encoding inside it would make a `.jpg` file hold TIFF data and mislead every tool and reader; a `.tif` name costs a legacy lookup, which only the painted types (horizon, merged horizon, per-frame reference) get because they cannot be recomputed. Caches are simply rebuilt, and `intermediateFormatVersion` forces that once.
