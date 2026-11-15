#!/bin/bash
set -e
grep -q 'ui.info_detailed_closing' StarCore/Sources/StarCore/Resources/Localizations/en.json
grep -q 'ui.info_detailed_closing' StarCore/Sources/StarCore/Resources/Localizations/ja.json
grep -q 'ui.info_detailed_horizon_title' gui/star/InfoDialogView.swift
grep -q 'ui.info_detailed_horizon_title' star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/InfoDialog.kt
! grep -q 'neibhgoring' StarCore/Sources/StarCore/Resources/Localizations/en.json
python3 i18n/check.py >/dev/null
echo "s414 OK"
