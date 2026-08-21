# OH2P AirPlay 2 Receiver PoC

This document tracks an isolated proof of concept for running an AirPlay 2 receiver on Xiaomi Smart Speaker Pro (OH2P) firmware 1.62.2.

## Scope and safety boundaries

- Base branch: `feature/oh2p-1.62.2`
- PoC branch: `feature/oh2p-airplay2-poc`
- Do not modify the squashfs/rootfs for this PoC.
- Do not replace or disable Xiaomi `mibrain`, `mediaplayer`, Bluetooth or USB Audio persistently.
- Runtime payload target: `/data/open-xiaoai/addons/airplay2/`.
- No Debian rootfs/chroot is shipped to the speaker.
- This PoC only proves buildability, dependency size and deployability. It does **not** claim AirPlay 2 works on OH2P until tested on hardware.

## Known OH2P runtime facts

- Model: Xiaomi Smart Speaker Pro / OH2P
- Firmware: 1.62.2
- Kernel: Linux 4.9.61 / LEDE
- CPU: 4 x Cortex-A53 ~1.2 GHz
- Kernel architecture: aarch64
- Userspace ABI: 32-bit ARM hard-float (`/lib/ld-linux-armhf.so.3`)
- RAM: about 256 MB
- `/data` free space: about 117 MB
- ALSA speaker: `card 0, device 2` (`TDM-C-acm8625p`)
- Known working PCM path: S16_LE, stereo, 48000 Hz
- Xiaomi `mediaplayer` normally owns `hw:0,2`
- Existing mDNS daemon: `mdnsd`
- No ffmpeg or avahi-daemon is known to be present
- root / SSH / `/data/init.sh` are available

## Upstream AirPlay 2 requirements checked for this PoC

Current Shairport Sync upstream documentation requires AirPlay 2 builds to use:

- Shairport Sync built with `--with-airplay-2`
- NQPTP companion daemon for AirPlay 2 timing
- OpenSSL (`--with-ssl=openssl` is mandatory for AirPlay 2)
- Avahi (`--with-avahi` is mandatory for AirPlay 2)
- ALSA for direct OH2P playback
- FFmpeg libraries; AirPlay 2 automatically enables FFmpeg use
- FFmpeg AAC decoding capable of floating planar (`fltp`) material
- libplist
- libsodium
- libgcrypt
- libuuid
- libpopt
- libconfig

`libsoxr` is recommended upstream for improved resampling but is optional. The first OH2P PoC intentionally does not enable it so the minimum dependency footprint can be measured first.

NQPTP must have exclusive access to UDP ports 319 and 320. Shairport Sync and NQPTP must also use compatible shared-memory interface versions.

## OH2P-specific risks to validate

1. **ABI / libc compatibility**: binaries built against a modern Debian armhf userspace may require a newer glibc than OH2P LEDE provides. Build success alone does not prove runtime compatibility.
2. **mDNS**: AirPlay 2 upstream requires Avahi. OH2P already runs Xiaomi `mdnsd`; coexistence on UDP 5353 and D-Bus availability must be checked on device.
3. **ALSA ownership**: Xiaomi `mediaplayer` normally owns `hw:0,2`. Initial testing may require stopping it temporarily. No persistent takeover/recovery mechanism is part of phase 1.
4. **Audio format**: the known-good hardware format is S16_LE stereo 48 kHz. Shairport Sync/FFmpeg conversion to this format must be tested.
5. **PTP ports**: UDP 319/320 must be free and reachable.
6. **Memory/storage**: FFmpeg and Avahi are expected to dominate the runtime payload; the workflow records exact bundle sizes.

## Phase 1 deliverable

A GitHub Actions artifact containing an armhf runtime tree laid out for:

```text
/data/open-xiaoai/addons/airplay2/
  bin/
    shairport-sync
    nqptp
  lib/
    ...runtime shared libraries...
  etc/
    shairport-sync.conf
  scripts/
    check-oh2p.sh
    run-nqptp.sh
    run-shairport-sync.sh
  BUILD-INFO.txt
  DEPENDENCIES.txt
```

The artifact is deliberately self-contained under `/data`; no rootfs files are changed by deployment.
