# 1184: map scripts/ci/**, not scripts/**

Impact entries are unioned, so `"scripts/exit/**" = []` could not cancel `"scripts/**"`. We list the real
directory (`scripts/ci/`, the only other one under scripts/) so exit scripts select nothing.
