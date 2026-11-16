#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "artSide: CGFloat = 150" gui/star/StartupView.swift
grep -q "fitting: 80" gui/star/KeypointDivisorStartupView.swift
echo "s501 OK"
