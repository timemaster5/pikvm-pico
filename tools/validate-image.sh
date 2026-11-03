#!/bin/bash
# Offline checks of an image built by build-image.sh. Run on the Docker host:
#   tools/validate-image.sh <raw .img> [toolbox image]
# The toolbox image is the one pi-builder made for the build (pi-builder.<project>.toolbox).
set -Eeuo pipefail
img=$(realpath "$1")
toolbox=${2:-pi-builder.pikvm-os.v1-hdmi-pico.toolbox}
docker run --rm --privileged -v /dev:/dev -v "$img":/image.img:ro "$toolbox" bash -Eeuo pipefail -c '
loop=$(losetup --find --show --read-only --partscan /image.img)
mnt=$(mktemp -d)
cleanup() { for m in dev proc tmp boot var/lib/kvmd/pst var/lib/kvmd/data ""; do umount "$mnt/$m" 2>/dev/null || true; done; losetup -d "$loop"; rmdir "$mnt"; }
trap cleanup EXIT
fail=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

echo "== partitions"
parted -s "$loop" unit MiB print
for pair in "1 PIBOOT vfat" "2 PIPST ext4" "3 PIROOT ext4" "4 PIDATA ext4"; do
	read -r n label type <<< "$pair"
	dev=${loop}p$n
	check "partition $n is $label/$type" "[[ \$(blkid -s LABEL -o value $dev) == $label && \$(blkid -s TYPE -o value $dev) == $type ]]"
	if [[ $type == vfat ]]; then fsck.fat -n "$dev" > /dev/null; else e2fsck -fn "$dev" > /dev/null; fi
done
mount -o ro,noload "${loop}p3" "$mnt"
mount -o ro "${loop}p1" "$mnt/boot"
mount -o ro,noload "${loop}p2" "$mnt/var/lib/kvmd/pst"
mount -o ro,noload "${loop}p4" "$mnt/var/lib/kvmd/data"
mount --bind /dev "$mnt/dev"; mount -t proc proc "$mnt/proc"; mount -t tmpfs tmpfs "$mnt/tmp"
cp -a "$mnt/etc/pacman.d/gnupg" "$mnt/tmp/gnupg"
df -h "$mnt" "$mnt/var/lib/kvmd/data" | cat

echo "== pacman"
conf=$mnt/etc/pacman.conf
check "[pikvm-pico] above [pikvm]" "[[ \$(grep -n \"^\\[pikvm-pico\\]\" $conf | cut -d: -f1) -lt \$(grep -n \"^\\[pikvm\\]\" $conf | cut -d: -f1) ]]"
grep -A3 "^\[pikvm-pico\]" "$conf"
chroot "$mnt" pacman -Q kvmd kvmd-platform-v1-hdmi-rpi3 pikvm-pico openocd-bcm2835
check "versions" "[[ \$(chroot $mnt pacman -Q kvmd kvmd-platform-v1-hdmi-rpi3 pikvm-pico openocd-bcm2835 | tr \"\n\" \"|\") == \"kvmd 4.234-101|kvmd-platform-v1-hdmi-rpi3 4.234-101|pikvm-pico 0.1.0-1|openocd-bcm2835 0.12.0-1|\" ]]"
check "no Arch openocd package" "! chroot $mnt pacman -Qq | grep -qx openocd"
check "no package from another arch" "! grep -L -x -e aarch64 -e any \$(ls $mnt/var/lib/pacman/local/*/desc) >/dev/null 2>&1 || true"
fpr=ABACF78B0CED70F1C1BDF80A526D5E07A31B4AF7
check "key in keyring" "chroot $mnt pacman-key --gpgdir /tmp/gnupg --list-keys $fpr > /dev/null 2>&1"
echo "-- key signatures (lsign shows as local):"
chroot "$mnt" pacman-key --gpgdir /tmp/gnupg --list-sigs "$fpr" 2>&1 | sed -n "1,12p"
check "key locally signed" "chroot $mnt pacman-key --gpgdir /tmp/gnupg --list-sigs $fpr 2>&1 | grep -Eq \"^sig +L\""
echo "-- owner check: regular files under /usr/local and /etc/systemd/system"
find "$mnt/usr/local" "$mnt/etc/systemd/system" -mindepth 1 -type f | sed "s|^$mnt||" | while read -r f; do
	o=$(chroot "$mnt" pacman -Qoq "$f" 2>/dev/null || echo UNOWNED)
	echo "$f -> $o"
done
echo "-- unowned files elsewhere in /etc/kvmd, /usr/share/pikvm-pico:"
find "$mnt/etc/kvmd" "$mnt/usr/share/pikvm-pico" -type f | sed "s|^$mnt||" | while read -r f; do
	chroot "$mnt" pacman -Qoq "$f" > /dev/null 2>&1 || echo "UNOWNED $f"
done

echo "== configuration"
sed -n "/^# pikvm-pico/,\$p" "$mnt/etc/kvmd/override.yaml"
check "override.yaml pico block" "grep -q \"type: pico_spi\" $mnt/etc/kvmd/override.yaml && grep -q \"type: pico_msd\" $mnt/etc/kvmd/override.yaml && grep -q \"type: disabled\" $mnt/etc/kvmd/override.yaml"
check "kvmd-pico-storage enabled" "[[ -L $mnt/etc/systemd/system/multi-user.target.wants/kvmd-pico-storage.service ]]"
check "kvmd enabled" "[[ -L $mnt/etc/systemd/system/multi-user.target.wants/kvmd.service ]]"
check "no ssh host keys" "! ls $mnt/etc/ssh/ssh_host_* > /dev/null 2>&1"
check "no web/VNC certificates" "! ls $mnt/etc/kvmd/nginx/ssl/* $mnt/etc/kvmd/vnc/ssl/* > /dev/null 2>&1"
check "machine-id empty or absent" "[[ ! -s $mnt/etc/machine-id ]]"
check "FIRST_BOOT=1 set" "grep -q FIRST_BOOT=1 $mnt/boot/pikvm.txt"
check "hostname pikvm" "[[ \$(cat $mnt/etc/hostname) == pikvm ]]"
check "no wifi config" "! ls $mnt/etc/netctl/* $mnt/etc/wpa_supplicant/*.conf $mnt/etc/systemd/network/*wlan* > /dev/null 2>&1"
check "DHCP network file" "grep -q DHCP $mnt/etc/systemd/network/eth0.network"
echo "-- accounts with a password, compared with the stock defaults (never printed):"
hashcheck() { # file field-name user default
	h=$(awk -F: -v u="$3" "\$1==u {print \$2}" "$mnt/$1")
	[[ -n $h ]] || { echo "     $1 $3: no password hash"; return; }
	if [[ $(chroot "$mnt" perl -e "print crypt(\$ARGV[0], \$ARGV[1])" "$4" "$h") == "$h" ]]; then echo "PASS  $1 $3 = stock default ($2)"; else echo "FAIL  $1 $3 differs from stock default"; fail=1; fi
}
awk -F: "\$2 !~ /^[!*]/ && \$2 != \"\" {print \"     shadow account with a hash - \" \$1}" "$mnt/etc/shadow"
hashcheck etc/shadow shadow root root
python3 - "$mnt/etc/kvmd/htpasswd" <<PY || fail=1
import base64, hashlib, sys
for line in open(sys.argv[1]):
    user, _, h = line.strip().partition(":")
    if user == "admin" and h.startswith("{SSHA512}"):
        raw = base64.b64decode(h[9:]); salt = raw[64:]
        ok = hashlib.sha512(b"admin" + salt).digest() == raw[:64]
        print(("PASS" if ok else "FAIL"), " etc/kvmd/htpasswd admin = stock default (admin)" if ok else " htpasswd admin differs"); sys.exit(0 if ok else 1)
print("FAIL  no admin entry in htpasswd"); sys.exit(1)
PY
grep -q "^admin:admin$" "$mnt/etc/kvmd/ipmipasswd" && echo "PASS  etc/kvmd/ipmipasswd admin = stock default (admin)" || { echo "FAIL  ipmipasswd"; fail=1; }
echo "-- users in kvmd password files:"
for f in htpasswd ipmipasswd vncpasswd; do echo "$f: $(grep -v "^#" "$mnt/etc/kvmd/$f" | grep -v "^$" | cut -d: -f1 | tr "\n" " ")"; done
check "no alarm user home" "! ls $mnt/home | grep -qx alarm"
check "no firmware-ti/-amd" "! chroot $mnt pacman -Qq | grep -qx -e linux-firmware-ti -e linux-firmware-amd"
echo "-- .pacnew/.pacsave left in /etc (stock pikvm/os leftovers are fine):"
find "$mnt/etc" -name "*.pacnew" -o -name "*.pacsave"
echo "-- boot"
grep -v "^#" "$mnt/boot/config.txt" | grep -v "^$"
cat "$mnt/boot/cmdline.txt"
echo "-- fstab"
cat "$mnt/etc/fstab"
echo "-- partition table of pacman.conf mirrors"
grep -n "^Server\|^Include\|^\[" "$mnt/etc/pacman.conf"
[[ $fail == 0 ]] && echo "ALL CHECKS PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
'
