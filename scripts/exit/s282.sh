#!/bin/bash
# Desktop StarArtTest and the art export check.
set -e
python3 art/export.py --check
cd star-desktop
STAR_USE_GPU_FOR_MERGE=0 ./gradlew test --tests '*StarArtTest*'
