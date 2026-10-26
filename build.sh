#!/bin/bash
# Build KeyLight.app from source (macOS, needs Xcode Command Line Tools).
# Giong cach build FixNotif: 1 file Swift, bien dich truc tiep bang swiftc.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p KeyLight.app/Contents/MacOS KeyLight.app/Contents/Resources
# Chi Apple Silicon (arm64): build tren may Apple Silicon se ra ban arm64.
# Khong build universal Intel, app khong ho tro may Intel.
swiftc -o KeyLight.app/Contents/MacOS/KeyLight KeyLight.swift
cp Info.plist KeyLight.app/Contents/Info.plist
cp AppIcon.icns KeyLight.app/Contents/Resources/AppIcon.icns
echo "Built KeyLight.app - open it, then try Option + Up/Down arrows."
