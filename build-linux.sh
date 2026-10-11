#!/usr/bin/env bash

# Build Linux variants and Windows variants from main.go.
# Run this script from the directory containing go.mod.
#
# Defaults:
#   Linux:   GOARCH reported by the installed Go toolchain
#   Windows: amd64
#
# Examples:
#   ./build-linux.sh
#   LINUX_ARCH=arm64 WINDOWS_ARCH=arm64 ./build-linux.sh

set -euo pipefail

LINUX_ARCH=${LINUX_ARCH:-$(go env GOARCH)}
WINDOWS_ARCH=${WINDOWS_ARCH:-amd64}
OUTPUT_ROOT=${OUTPUT_ROOT:-bin}
LINUX_DIR="$OUTPUT_ROOT/linux/$LINUX_ARCH"
WINDOWS_DIR="$OUTPUT_ROOT/windows/$WINDOWS_ARCH"

targets=$(go tool dist list)
if ! grep -Fqx -- "linux/$LINUX_ARCH" <<<"$targets"; then
    echo "Unsupported Linux target: linux/$LINUX_ARCH" >&2
    echo "Use: go tool dist list" >&2
    exit 2
fi
if ! grep -Fqx -- "windows/$WINDOWS_ARCH" <<<"$targets"; then
    echo "Unsupported Windows target: windows/$WINDOWS_ARCH" >&2
    echo "Use: go tool dist list" >&2
    exit 2
fi

mkdir -p "$LINUX_DIR" "$WINDOWS_DIR"

echo "Building Linux/$LINUX_ARCH variants..."
GOOS=linux GOARCH="$LINUX_ARCH" go build -buildvcs=false \
	-o "$LINUX_DIR/go-default" .
GOOS=linux GOARCH="$LINUX_ARCH" go build -buildvcs=false -trimpath \
	-o "$LINUX_DIR/go-trimpath" .
GOOS=linux GOARCH="$LINUX_ARCH" go build -buildvcs=false -ldflags='-s -w' \
	-o "$LINUX_DIR/go-stripped" .
CGO_ENABLED=0 GOOS=linux GOARCH="$LINUX_ARCH" go build -buildvcs=false \
	-o "$LINUX_DIR/go-nocgo" .
CGO_ENABLED=0 GOOS=linux GOARCH="$LINUX_ARCH" go build -buildvcs=false \
	-trimpath -ldflags='-s -w -buildid=' -o "$LINUX_DIR/go-minimal" .

echo "Building Windows/$WINDOWS_ARCH variants..."
GOOS=windows GOARCH="$WINDOWS_ARCH" go build -buildvcs=false \
	-o "$WINDOWS_DIR/go-default.exe" .
GOOS=windows GOARCH="$WINDOWS_ARCH" go build -buildvcs=false -trimpath \
	-o "$WINDOWS_DIR/go-trimpath.exe" .
GOOS=windows GOARCH="$WINDOWS_ARCH" go build -buildvcs=false -ldflags='-s -w' \
	-o "$WINDOWS_DIR/go-stripped.exe" .
CGO_ENABLED=0 GOOS=windows GOARCH="$WINDOWS_ARCH" go build -buildvcs=false \
	-o "$WINDOWS_DIR/go-nocgo.exe" .
CGO_ENABLED=0 GOOS=windows GOARCH="$WINDOWS_ARCH" go build -buildvcs=false \
	-trimpath -ldflags='-s -w -buildid=' -o "$WINDOWS_DIR/go-minimal.exe" .
GOOS=windows GOARCH="$WINDOWS_ARCH" go build -buildvcs=false \
	-ldflags='-buildid=' -o "$WINDOWS_DIR/go-no-buildid.exe" .

# PIE is optional because support depends on the target and Go toolchain.
if CGO_ENABLED=0 GOOS=linux GOARCH="$LINUX_ARCH" go build \
	-buildvcs=false -buildmode=pie -o "$LINUX_DIR/go-pie" .; then
	:
else
	echo "Skipping Linux/$LINUX_ARCH PIE: unsupported by this Go toolchain"
fi

echo
echo "Build complete:"
find "$OUTPUT_ROOT" -type f -print | sort
