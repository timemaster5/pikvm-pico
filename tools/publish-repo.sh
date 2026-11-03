#!/bin/bash
# Sign the packages in dist/ and build the signed pacman database "pikvm-pico" next to them.
# Upload the contents of dist/ as assets of the GitHub Release tagged "repo". Nothing is uploaded here.
#
# PIKVM_PICO_GPG_KEY  key id or fingerprint of the repo signing key (required). The key lives in
#                     the owner's keychain/vault and gpg-agent; it is never stored in this repo.
# Needs gpg and repo-add (pacman's tool) on PATH; without repo-add the unsigned database is made
# in an Arch Linux ARM container and signed here.
set -Eeuo pipefail

: "${PIKVM_PICO_GPG_KEY:?set PIKVM_PICO_GPG_KEY to the signing key id}"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dist=$root/dist
name=pikvm-pico
image=${ARCH_IMAGE:-menci/archlinuxarm:latest}

shopt -s nullglob
pkgs=("$dist"/*.pkg.tar.zst "$dist"/*.pkg.tar.xz)
if (( ${#pkgs[@]} == 0 )); then
	echo "No packages in $dist, run tools/build-packages.sh first" >&2
	exit 1
fi

for pkg in "${pkgs[@]}"; do
	rm -f "$pkg.sig"
	gpg --batch --yes --local-user "$PIKVM_PICO_GPG_KEY" --detach-sign --output "$pkg.sig" "$pkg"
done

rm -f "$dist/$name".db* "$dist/$name".files*

if command -v repo-add >/dev/null; then
	repo-add --sign --key "$PIKVM_PICO_GPG_KEY" "$dist/$name.db.tar.gz" "${pkgs[@]}"
else
	docker run --rm --platform linux/arm64 -v "$dist:/dist" "$image" bash -Eeuo pipefail -c "
		cd /dist && repo-add $name.db.tar.gz *.pkg.tar.{zst,xz} 2>/dev/null || repo-add $name.db.tar.gz *.pkg.tar.xz"
	gpg --batch --yes --local-user "$PIKVM_PICO_GPG_KEY" --detach-sign --output "$dist/$name.db.tar.gz.sig" "$dist/$name.db.tar.gz"
fi

# Release assets are plain files: replace the symlinks repo-add creates with copies.
for link in "$dist/$name".db "$dist/$name".db.sig "$dist/$name".files "$dist/$name".files.sig; do
	if [[ -L $link ]]; then
		target=$(readlink "$link")
		rm -f "$link"
		cp "$dist/$target" "$link"
	fi
done

gpg --verify "$dist/$name.db.tar.gz.sig" "$dist/$name.db.tar.gz"
ls -l "$dist"
echo "Upload everything in $dist to the release tagged 'repo'."
