#!/bin/bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
app="$root/CameraCollector.app"
scratch="$(mktemp -d /private/tmp/camera-collector-build.XXXXXXXX)"
trap '/bin/rm -f "$scratch/CameraCollector"; /bin/rmdir "$scratch"' EXIT
xcrun swiftc -O -parse-as-library "$root/CameraCollector.swift" -o "$scratch/CameraCollector"
mkdir -p "$app/Contents/MacOS"
install -m 755 "$scratch/CameraCollector" "$app/Contents/MacOS/CameraCollector"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
