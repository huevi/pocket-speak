#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
arch="$(uname -m)"
case "$arch" in
  x86_64) upstream_arch=x86_64; sha=f04baa94d4fc47a689cc9f11ca2b0ba869dc002f9e78e15d387c6ecaeb1d654b ;;
  arm64) upstream_arch=aarch64; sha=ee9ca6c7c000ee72c5846e3a8ba01d08f56636d94a614d2259c3f12b8fd69afa ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
name="pocket-tts-3.3.0-${upstream_arch}-apple-darwin"
mkdir -p build
archive="build/$name.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --silent --show-error --retry 2 \
    "https://github.com/kyutai-labs/pocket-tts/releases/download/v4.0.1/$name.tar.gz" \
    -o "$tmp/$name.tar.gz"
  printf '%s  %s\n' "$sha" "$tmp/$name.tar.gz" | shasum -a 256 -c
  mv "$tmp/$name.tar.gz" "$archive"
fi
printf '%s  %s\n' "$sha" "$archive" | shasum -a 256 -c
tar -xzf "$archive" -C "$tmp"

app="$tmp/Pocket Speak.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/"
cp "$tmp/$name/pocket-tts" "$app/Contents/MacOS/"
cp "$tmp/$name/LICENSE" "$app/Contents/Resources/Pocket-TTS-LICENSE"
cp Resources/english.yaml "$app/Contents/Resources/"
sources=(PocketSpeak.swift ModelAssets.swift SetupWindow.swift)
flags=(-parse-as-library -swift-version 5 -O -target "$arch-apple-macos14.0")
if [[ "${1:-}" == "--check" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.github.huevi.pocket-speak.check' "$app/Contents/Info.plist"
  sources+=(Tests/SetupSmoke.swift)
  flags+=(-D SETUP_SMOKE_TEST)
fi
xcrun swiftc "${flags[@]}" "${sources[@]}" -o "$app/Contents/MacOS/PocketSpeak"
codesign --force --sign - "$app/Contents/MacOS/pocket-tts"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

if [[ "${1:-}" == "--check" ]]; then
  shift
  if [[ "${1:-}" == "offline" ]]; then
    /usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network-outbound) (allow network-outbound (remote ip "localhost:*"))'       "$app/Contents/MacOS/PocketSpeak" "$@"
  else
    "$app/Contents/MacOS/PocketSpeak" "$@"
  fi
else
  # Replace build output only after compiling and verifying a complete bundle.
  rm -rf "build/Pocket Speak.app"
  mv "$app" "build/Pocket Speak.app"
  printf 'Built %s\n' "$PWD/build/Pocket Speak.app"
fi
