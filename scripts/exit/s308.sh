#!/usr/bin/env bash
# Exit check for s308 (task #248): both prompts draw the before/after row.
set -euo pipefail
cd "$(dirname "$0")/../.."
grep -q beforeAndAfter gui/star/PostProcessingRenderPromptView.swift
grep -q BeforeAndAfter star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/RenderPromptDialogs.kt
echo S308-OK
