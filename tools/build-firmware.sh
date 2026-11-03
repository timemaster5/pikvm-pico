#!/bin/bash
# Build the Pico firmware (hid.uf2, hid.elf) from the kvmd fork tag in a Debian arm64 container
# into dist/. Arch Linux ARM has no arm-none-eabi toolchain for aarch64, so this is separate
# from build-packages.sh. The fork's hid/pico/Makefile pins pico-sdk, TinyUSB and ps2x2pico by
# commit and applies its patches; the build needs network access.
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${FW_IMAGE:-debian:bookworm}
tag=${KVMD_TAG:-v4.234-pico1}
repo=${KVMD_REPO:-https://github.com/timemaster5/kvmd.git}

mkdir -p "$root/dist"

docker run --rm --platform linux/arm64 \
	-v "$root/dist:/work/dist" \
	-e "TAG=$tag" -e "REPO=$repo" \
	"$image" bash -Eeuo pipefail -c '
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y --no-install-recommends ca-certificates git patch make cmake python3 \
		build-essential gcc-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib
	git clone --depth 1 --branch "$TAG" "$REPO" /build/kvmd
	make -C /build/kvmd/hid/pico
	cp /build/kvmd/hid/pico/.build/src/hid.uf2 /build/kvmd/hid/pico/.build/src/hid.elf /work/dist/
'

cd "$root/dist"
sha256sum hid.uf2 > hid.uf2.sha256
ls -l hid.uf2 hid.elf hid.uf2.sha256
cat hid.uf2.sha256
