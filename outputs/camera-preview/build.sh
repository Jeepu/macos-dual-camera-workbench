#!/bin/bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
scratch="$(mktemp -d /private/tmp/camera-studio-build.XXXXXXXX)"
trap '/usr/bin/find "$scratch" -type f -delete; /bin/rmdir "$scratch"' EXIT
xcrun clang -O2 -Wall -Wno-deprecated-declarations "$root/native/uvc-control.c" -framework IOKit -framework CoreFoundation -o "$scratch/uvc-control"
xcrun swiftc -O -D COLLECTOR_LIBRARY "$root/"*.swift "$root/../camera-collector/CameraCollector.swift" -o "$scratch/CameraPreview"
app="$root/双摄像头预览.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 644 "$root/native/uvc-write-verification.json" "$app/Contents/Resources/uvc-write-verification.json"
install -m 755 "$scratch/uvc-control" "$app/Contents/MacOS/uvc-control"
install -m 755 "$scratch/CameraPreview" "$app/Contents/MacOS/CameraPreview"
codesign --force --sign - "$app/Contents/MacOS/uvc-control"
codesign --force --sign - --requirements '=designated => identifier "local.dataset.dual-camera-preview"' "$app"
codesign --verify --strict "$app"
