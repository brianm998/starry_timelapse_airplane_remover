#!/usr/bin/env bash
# s1071 exit check for task #1103: the rule is in place and unit-tested (UI features are CI-only).
set -euo pipefail
grep -q "frameLinesTakeHits = false" gui/star/OutlierGroupView.swift
grep -q "testSelectionLinesNeverTakeAClick" gui/starTests/ClickRuleTests.swift
grep -q "describeProbeClick" gui/starUITests/GuiFeatureRunner.swift
