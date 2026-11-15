#!/bin/bash
set -e
grep -q 'ui.info_about_license' StarCore/Sources/StarCore/Resources/Localizations/en.json
grep -q 'STAR_SOURCE_URL' gui/star/InfoDialogView.swift
grep -q 'STAR_SOURCE_URL' star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/InfoDialog.kt
! grep -rq 'LINK to source code here' gui/star
echo "s407 OK"
