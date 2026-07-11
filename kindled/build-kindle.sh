#!/bin/sh
# Cross-compiles kindled for the Kindle (ARMv7, static musl).
#
# rustls' ring backend contains C/asm, so the build needs an ARM C
# cross-toolchain; the rust-musl-cross docker image provides it. Falls
# back to a local rustup build if docker is unavailable (needs
# CC_armv7_unknown_linux_musleabihf pointing at an ARM musl gcc).
set -eu

cd "$(dirname "$0")"
TARGET=armv7-unknown-linux-musleabihf
IMAGE=messense/rust-musl-cross:armv7-musleabihf

if command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$PWD":/home/rust/src "$IMAGE" \
        cargo build --release --target "$TARGET"
else
    rustup target list --installed | grep -q "$TARGET" || rustup target add "$TARGET"
    cargo build --release --target "$TARGET"
fi

BIN="target/$TARGET/release/kindled"
echo
echo "built: $BIN ($(du -h "$BIN" | cut -f1))"
echo "install: scp $BIN root@KINDLE_IP:/mnt/us/privatecloud/kindled"
