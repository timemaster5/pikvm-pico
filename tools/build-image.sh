#!/bin/bash
# Build the PiKVM v1 (Raspberry Pi 3, HDMI, aarch64) SD card image: stock pikvm/os plus the
# packages of this repository, installed from the signed pacman repository.
#
# Needs a Docker host with make, git, curl, xz and docker (privileged containers, loop devices):
# an aarch64 Linux machine, or the Colima VM on an Apple Silicon Mac, in which case run this
# script inside the VM (colima ssh) and keep WORK_DIR on the VM's own disk.
#
# The image has the stock PiKVM default passwords and no host keys, machine id or certificates;
# the first boot generates them. No secret is needed or written.
#
# Variables:
#   WORK_DIR  work tree (default: build/image in this repository); keep it for rebuilds
#   BASE_TGZ   optional: an Arch Linux ARM base tarball from an earlier build
#              (os/.pi-builder/base/arch-rpi3-aarch64.tgz) to skip the 800 MB download
#   OUT_DIR    where the .img.xz and its .sha256 go (default: dist/image)
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=${WORK_DIR:-$root/build/image}
OUT_DIR=${OUT_DIR:-$root/dist/image}

OS_URL=https://github.com/pikvm/os
OS_REV=628d27d9fba2f64f653ff666d174c691135ae55c
PI_BUILDER_URL=https://github.com/mdevaev/pi-builder
PI_BUILDER_REV=6ff08b118cf91046461c972fc60d741e07aeea86

# End of the last partition in image/stage/disk-v1-pico.conf; pi-builder adds 2 GiB of empty
# space after it, which is cut off again so that the image fits an 8 GB card.
disk_end=$((6656 * 1024 * 1024))

unset BUILD_DIR SSH_CLIENT SSH_CONNECTION SSH_TTY
mkdir -p "$WORK_DIR" "$OUT_DIR"

clone() { # url rev dir
	[[ -d $3/.git ]] || git clone "$1" "$3"
	git -C "$3" fetch --quiet origin
	git -C "$3" checkout --quiet "$2"
}
clone "$OS_URL" "$OS_REV" "$WORK_DIR/os"
clone "$PI_BUILDER_URL" "$PI_BUILDER_REV" "$WORK_DIR/os/.pi-builder"

if [[ -n ${BASE_TGZ:-} ]]; then
	mkdir -p "$WORK_DIR/os/.pi-builder/base"
	[[ -e "$WORK_DIR/os/.pi-builder/base/arch-rpi3-aarch64.tgz" ]] || cp "$BASE_TGZ" "$WORK_DIR/os/.pi-builder/base/arch-rpi3-aarch64.tgz"
fi

# The pikvm stage fails on the Arch firmware split (linux-firmware-ti/-amd own files of the
# PiKVM firmware packages): the patch removes those two packages first. Nothing else is changed.
git -C "$WORK_DIR/os" checkout --quiet -- stages
git -C "$WORK_DIR/os" apply "$root/image/os-pikvm-firmware.patch"

# Our stage lives next to the stages of pi-builder, where its Makefile collects them from.
stage=$WORK_DIR/os/.pi-builder/stages/arch/pikvm-pico
rm -rf "$stage"
cp -a "$root/image/stage/pikvm-pico" "$stage"
cp "$root/keys/pikvm-pico.asc" "$stage/pikvm-pico.asc"
cp "$root/image/stage/disk-v1-pico.conf" "$WORK_DIR/os/disk/v1-pico.conf"

cd "$WORK_DIR/os"
rm -f images/v1-hdmi-rpi3/aarch64/*-pico-*.img
make_args=(
	PLATFORM=v1-hdmi BOARD=rpi3 ARCH=aarch64 SUFFIX=-pico
	ARCH_DIST_REPO_URL=https://de3.mirror.archlinuxarm.org
	DISK="$PWD/disk/v1-pico.conf"
	"STAGES=__init__ os pikvm-repo pistat watchdog rootdelay ro pikvm pikvm-pico restore-mirrorlist __cleanup__"
	IMAGE_XZ=0
	SHELL='/bin/bash --norc'
	DOCKER_RUN_TTY='docker run --rm'
)
make os "${make_args[@]}"
make image "${make_args[@]}"

img=$(ls -t images/v1-hdmi-rpi3/aarch64/v1-hdmi-rpi3-aarch64-pico-[0-9]*.img | head -n1)
python3 - "$img" "$disk_end" <<'PY'
import os, struct, sys
path, want = sys.argv[1], int(sys.argv[2])
with open(path, 'rb') as f:
    mbr = f.read(512)
assert mbr[510:512] == b'\x55\xaa'
ends = []
for i in range(4):
    start, size = struct.unpack_from('<II', mbr, 446 + i * 16 + 8)
    if size:
        ends.append((start + size) * 512)
assert len(ends) == 4 and max(ends) == want, ends
os.truncate(path, want)
PY

name=$(basename "$img")
xz -T0 -6 -c "$img" > "$OUT_DIR/$name.xz"
(cd "$OUT_DIR" && sha256sum "$name.xz" > "$name.xz.sha256")
ls -l "$OUT_DIR"
