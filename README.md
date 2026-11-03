> **About this fork.** Thank you to the PiKVM project and its authors for KVMD. A Raspberry Pi 3 and a Pico were free on my desk, and with these additions they do everything I need from a KVM, so here it is. This branch stays as close to upstream as we can keep it, so it could be merged one day, but that is not the goal.
>
> Added on branch `pico-spi-storage`:
> - USB mass storage (virtual CD/DVD and flash drive, read-only or writable) served by the Raspberry Pi Pico over SPI, in the normal Drive menu
>   - Speed: about 370 kB/s read (USB 1.1 full speed on the Pico), roughly 22 MB per minute: a Debian mini.iso/netboot image (~60 MB) loads in about 3 minutes, a full netinst ISO (~700 MB) in about 30 minutes. Best for small netboot/installer images.
> - Faster Pico SPI transport (framed protocol with CRC32, DMA, read-ahead) shared by HID and storage
> - Runs on Raspberry Pi 3 with an aarch64 (64-bit) system
>
> Packages and install notes: [timemaster5/pikvm-pico](https://github.com/timemaster5/pikvm-pico). Details: [FORK.md](https://github.com/timemaster5/kvmd/blob/pico-spi-storage/FORK.md). License: GPL-3.0, as upstream.

# pikvm-pico

Packages and a signed pacman repository for the [`pico-spi-storage`](https://github.com/timemaster5/kvmd/tree/pico-spi-storage) fork of KVMD: a PiKVM v1 (Raspberry Pi 3 plus a Raspberry Pi Pico for keyboard, mouse and USB mass storage) that keeps receiving the normal PiKVM updates. Install on top of an official PiKVM image instead of building an image yourself.

| package | content |
|---|---|
| `kvmd` | KVMD 4.234 from the fork: `kvmd-pico-storage` broker (`/run/kvmd/pico-storage.sock`), `pico_spi` HID and `pico_msd` MSD plugins, `kvmd-pico-storage.service` |
| `kvmd-platform-v1-hdmi-rpi3` | the platform package for the above (it pins the exact `kvmd` build) |
| `pikvm-pico` | Pico firmware (`hid.uf2`, `hid.elf`), `pikvm-pico-flash`, SWD config |
| `openocd-bcm2835` | OpenOCD 0.12.0 with the Raspberry Pi GPIO SWD driver (Arch and Arch Linux ARM build OpenOCD without it) |

Packages are for aarch64 (64-bit Arch Linux ARM, as the official PiKVM images).

## Hardware

Raspberry Pi 3 (3B+) with a Pico wired to it as in the DIY PiKVM v1 HID bridge. Raspberry Pi side
(BCM numbering):

| function | Pi GPIO | Pico |
|---|---|---|
| SPI MOSI | 10 | GP20 (SPI0 RX) |
| SPI MISO | 9 | GP19 (SPI0 TX) |
| SPI SCLK | 11 | GP18 |
| chip select (software) | 7 | GP21 |
| Pico reset | 25 | RUN |
| power detect | 16 | Pico power (VBUS or 3V3 through the divider you use) |
| SWD clock | 5 | SWCLK |
| SWD data | 6 | SWDIO |
| ground | any GND | GND, and the SWD GND pad |

The Pico's USB port goes to the target computer. SPI runs in mode 1 at 8 MHz.
The SWD wires are only needed to flash the Pico without touching it; BOOTSEL works without them.

## Install on an official PiKVM v1 image

As root on the PiKVM, with the system writable (`rw`; `ro` afterwards):

1. Add the repository **above** `[pikvm]` in `/etc/pacman.conf`. The first repository that has a package wins, so our `kvmd` is used and upstream's is not:

   ```
   [pikvm-pico]
   Server = https://github.com/timemaster5/pikvm-pico/releases/download/repo
   SigLevel = Required DatabaseRequired TrustedOnly

   [pikvm]
   ...
   ```

2. Import the signing key (fingerprint `ABACF78B0CED70F1C1BDF80A526D5E07A31B4AF7`; the public key is the release asset `pikvm-pico.gpg`) and trust it:

   ```
   curl -fL https://github.com/timemaster5/pikvm-pico/releases/download/repo/pikvm-pico.gpg | pacman-key --add -
   pacman-key --lsign-key ABACF78B0CED70F1C1BDF80A526D5E07A31B4AF7
   ```

   Compare the fingerprint with the one published in this README before trusting it.

3. Update and install:

   ```
   pikvm-update
   pacman -S pikvm-pico
   ```

   `pikvm-update` replaces `kvmd` and `kvmd-platform-v1-hdmi-rpi3` with our builds and updates everything else as usual.

4. Optional safety net: if our repository ever disappears, an upstream `kvmd` would silently replace ours and the Pico stops working. In `/etc/pacman.conf` under `[options]`:

   ```
   IgnorePkg = kvmd kvmd-platform-*
   ```

   `pikvm-update` then skips these two; update them explicitly with `pacman -S kvmd kvmd-platform-v1-hdmi-rpi3 pikvm-pico`.

5. Configure (below), flash the Pico (below), then `systemctl enable --now kvmd-pico-storage` and `systemctl restart kvmd`.

## Ready-made SD image

`tools/build-image.sh` builds a flashable image for the PiKVM v1 on a Raspberry Pi 3 (HDMI, aarch64) from the stock [pikvm/os](https://github.com/pikvm/os) builder. The only addition is a build stage (`image/stage/pikvm-pico/`) that does what the install section above does by hand: it imports the signing key, adds `[pikvm-pico]` above `[pikvm]`, installs `kvmd`, `kvmd-platform-v1-hdmi-rpi3`, `pikvm-pico` and `openocd-bcm2835` from the repository, writes the site configuration below, and enables `kvmd-pico-storage`. No file is copied into the image outside of packages except that configuration.

- Layout (6.5 GiB, fits an 8 GB card): `PIBOOT` 256 MiB, `PIPST` 256 MiB, `PIROOT` 4 GiB (read-only as in stock PiKVM), `PIDATA` 2 GiB mounted at `/var/lib/kvmd/data` (read-write, holds the images served by the Pico).
- `/etc/kvmd/override.yaml` gets `hid: pico_spi`, `msd: pico_msd` with `images_dir: /var/lib/kvmd/data/images`, `atx: disabled` and `picostorage.images_dir`. This is per-site: edit `image/stage/pikvm-pico/override.yaml` before building if your wiring differs.
- Stock PiKVM defaults apply: hostname `pikvm`, DHCP, `root`/`root`, web `admin`/`admin`. No WiFi, no secrets. SSH host keys, machine id and the web certificate are generated on the first boot. Change the passwords right away (`rw`, `passwd`, `kvmd-htpasswd set admin`, `ro`).
- Build (aarch64 Docker host; on an Apple Silicon Mac inside the Colima VM, with `WORK_DIR` on the VM disk): `tools/build-image.sh`, result `dist/image/v1-hdmi-rpi3-aarch64-pico-<date>.img.xz` and its `.sha256`.

Burn it: check the sum, then write the decompressed image to the card (replace `diskN`; `lsblk` on Linux):

```
shasum -a 256 -c v1-hdmi-rpi3-aarch64-pico-<date>.img.xz.sha256
xz -dc v1-hdmi-rpi3-aarch64-pico-<date>.img.xz | sudo dd of=/dev/rdiskN bs=4m
```

Put the card in the Pi, wait for the first boot to finish (it reboots once), and open `https://pikvm/`. Updates later are the normal `pikvm-update`; our packages come from the repository because it is above `[pikvm]`. Flash the Pico as described below.

## Configuration

`/etc/kvmd/override.yaml`:

```yaml
kvmd:
    hid:
        type: pico_spi
        reset_pin: 25
        reset_inverted: true
        reset_self: true
        power_detect_pin: 16
        power_detect_pull_down: true
    msd:
        type: pico_msd
    atx:
        type: disabled    # no ATX circuit on the board

picostorage:
    images_dir: /var/lib/kvmd/msd/images
    spi:
        bus: 0
        chip: 0
        speed: 8000000
        mode: 1
        cs_pin: 7
```

Drop the `atx` part if the board has the ATX circuit. Images are uploaded and selected in the normal Drive menu of the web UI.

## Flashing the Pico

The firmware must match the installed `kvmd`: the SPI protocol of this fork is not compatible with the stock Pico firmware.

- Over SWD from the Pi (needs the SWD wires): `pikvm-pico-flash --probe` shows the RP2040, then `pikvm-pico-flash` flashes `/usr/share/pikvm-pico/hid.elf` (it stops `kvmd` and the broker and starts them again).
- Over USB: hold BOOTSEL while plugging the Pico into a computer, then copy `/usr/share/pikvm-pico/hid.uf2` to the `RPI-RP2` drive.

## Limits and speed

- Speed: about 370 kB/s read (USB 1.1 full speed on the Pico), roughly 22 MB per minute: a Debian mini.iso/netboot image (~60 MB) loads in about 3 minutes, a full netinst ISO (~700 MB) in about 30 minutes. Best for small netboot/installer images.
- Writes are slower than reads (every block is written through and synced).
- ISO data discs only; audio CDs and raw BIN/CUE are not supported.
- Booting an installer image end to end is not yet verified; the figures are read speeds.
- Only the `v1-hdmi` platform on a Raspberry Pi 3 is packaged. Other PiKVM models are not touched.

## Updating

Our `kvmd` is the upstream release plus the fork branch, rebuilt for each upstream release: rebase `pico-spi-storage` on the new tag, build the packages with `tools/build-packages.sh`, sign and publish with `tools/publish-repo.sh`. Package versions are `<upstream version>-<100 + n>`, e.g. `4.234-101`. Until our build of a new upstream version is published, `pikvm-update` keeps updating all other packages and leaves `kvmd` as it is.

## Building

```
tools/build-firmware.sh           # Debian arm64 container: hid.uf2, hid.elf, hid.uf2.sha256 into dist/
tools/build-packages.sh           # aarch64 Arch Linux ARM container, packages into dist/ (needs dist/hid.uf2)
PIKVM_PICO_GPG_KEY=<key id> tools/publish-repo.sh   # sign, make the database in dist/
tools/check-identity.sh           # before every push
```

The firmware is built separately because Arch Linux ARM has no arm-none-eabi toolchain for aarch64. `pikvm-pico` takes `hid.uf2` as the asset of the GitHub release `fw-v<kvmd version>-pico1` (checksum pinned in its PKGBUILD); locally `build-packages.sh` places `dist/hid.uf2` next to the PKGBUILD so makepkg needs no download. Publish `hid.uf2` to that release before a clean build elsewhere.

`dist/` is uploaded as assets of the GitHub Release tagged `repo`. The signing key is never part of this repository.

## Credits

- [PiKVM](https://github.com/pikvm/kvmd) by Maxim Devaev and contributors; the `kvmd` PKGBUILD here follows [pikvm/packages](https://github.com/pikvm/packages).
- The `openocd-bcm2835` PKGBUILD follows the Arch Linux `openocd` package; [OpenOCD](https://openocd.org) is GPL-2.0-or-later, built from the upstream tag.
- [pico-sdk](https://github.com/raspberrypi/pico-sdk), [TinyUSB](https://github.com/hathach/tinyusb) and [ps2x2pico](https://github.com/No0ne/ps2x2pico), used by the firmware at pinned commits.

## License

GPL-3.0, see [LICENSE](LICENSE).
