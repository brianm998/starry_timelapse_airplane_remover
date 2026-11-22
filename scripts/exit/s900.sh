#!/bin/bash
set -e
cd "$(dirname "$0")/../../StarCore"
STAR_USE_GPU_FOR_MERGE=0 swift test --filter 'StopThenStartTests|FrameGraphBuilderCancelTests'
