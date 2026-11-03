#!/bin/bash
# Build all packages in an Arch Linux ARM (aarch64) container into dist/.
# Needs docker (Colima or Docker Desktop on an arm64 Mac, or an aarch64 Linux host).
# The image is a community-maintained Arch Linux ARM rootfs; override with ARCH_IMAGE and
# pin a digest (name@sha256:...) for reproducible builds.
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${ARCH_IMAGE:-menci/archlinuxarm:latest}
packages=(openocd-bcm2835 kvmd pikvm-pico)

mkdir -p "$root/dist"

# makepkg refuses root, so the build runs as an unprivileged "builder" user.
# -d: runtime depends come from the [pikvm] repository, which the container does not have;
# only makedepends are installed, by name below.
docker run --rm --platform linux/arm64 \
	-v "$root/packages:/work/packages:ro" \
	-v "$root/dist:/work/dist" \
	-e "PACKAGES=${packages[*]}" \
	"$image" bash -Eeuo pipefail -c '
	# pacman 7 sandboxes downloads with Landlock, which containers usually do not allow.
	sed -i "s/^#DisableSandbox/DisableSandbox/" /etc/pacman.conf
	grep -q "^DisableSandbox" /etc/pacman.conf || sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf
	pacman-key --init
	pacman-key --populate archlinuxarm
	pacman -Syu --noconfirm --needed base-devel git cmake sudo \
		python-build python-installer python-wheel python-setuptools \
		arm-none-eabi-gcc arm-none-eabi-newlib \
		hidapi jimtcl libjaylink libusb libftdi-compat capstone
	useradd -m builder
	install -d -o builder -g builder /build
	chown builder:builder /work/dist
	for p in $PACKAGES; do
		cp -r "/work/packages/$p" "/build/$p"
		chown -R builder:builder "/build/$p"
		su builder -c "cd /build/$p && PKGDEST=/work/dist makepkg -d --noconfirm --cleanbuild"
	done
'

ls -l "$root/dist"
