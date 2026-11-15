#!/bin/bash
set -e
grep -q 'struct WorkflowStrip' gui/star/InfoDialogView.swift
grep -q 'fun WorkflowStrip' star-desktop/src/main/kotlin/com/star/desktop/ui/dialogs/InfoDialog.kt
echo "s344 OK"
