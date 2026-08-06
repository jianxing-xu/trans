#!/bin/zsh

set -euo pipefail

TRANS_PROJECT_ROOT="${0:A:h:h}"
TRANS_BUILD_ROOT="$TRANS_PROJECT_ROOT/.build"
TRANS_APP="$TRANS_PROJECT_ROOT/build/Trans.app"
TRANS_BINARY_DIRECTORY="$TRANS_BUILD_ROOT/direct-release"
TRANS_MODULE_CACHE="$TRANS_BUILD_ROOT/direct-module-cache"
TRANS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
TRANS_ARCH="$(uname -m)"

case "$TRANS_ARCH" in
    arm64|x86_64) ;;
    *)
        echo "Unsupported architecture: $TRANS_ARCH" >&2
        exit 1
        ;;
esac

mkdir -p "$TRANS_BINARY_DIRECTORY"
mkdir -p "$TRANS_MODULE_CACHE"

swiftc \
    -O \
    -whole-module-optimization \
    -target "$TRANS_ARCH-apple-macosx12.0" \
    -sdk "$TRANS_SDK" \
    -module-cache-path "$TRANS_MODULE_CACHE" \
    "$TRANS_PROJECT_ROOT"/Sources/Trans/*.swift \
    -o "$TRANS_BINARY_DIRECTORY/Trans"

mkdir -p "$TRANS_APP/Contents/MacOS"
mkdir -p "$TRANS_APP/Contents/Resources"
install -m 755 "$TRANS_BINARY_DIRECTORY/Trans" "$TRANS_APP/Contents/MacOS/Trans"
install -m 644 "$TRANS_PROJECT_ROOT/Resources/Info.plist" "$TRANS_APP/Contents/Info.plist"

codesign \
    --force \
    --sign - \
    --requirements '=designated => identifier "com.trans.app"' \
    --timestamp=none \
    "$TRANS_APP"

echo "$TRANS_APP"
