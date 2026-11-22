#!/bin/bash
# Exit check for s933 (task #847): the output JPEG quality override, in StarCore, the daemon and the catalogue.
set -e
cd "$(dirname "$0")/../.."
python3 i18n/check.py | tail -1
(cd StarCore && STAR_USE_GPU_FOR_MERGE=0 swift test --filter "ConfigRoundTrip|JPEGOutputQualityTests")
(cd daemon && STAR_USE_GPU_FOR_MERGE=0 swift test --filter ExpertConfigFieldsTests)
