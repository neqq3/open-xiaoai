# OH2P AirPlay 2 Receiver PoC

This document tracks an isolated proof of concept for running an AirPlay 2 receiver on Xiaomi Smart Speaker Pro (OH2P) firmware 1.62.2.

## Scope and safety boundaries

- Base branch: `feature/oh2p-1.62.2`
- PoC branch: `feature/oh2p-airplay2-poc`
- Do not modify the squashfs/rootfs for this PoC.
- Do not modify `/data/init.sh` or enable automatic startup in phase 1.
- Do not automatically stop or kill Xiaomi `mdnsd`, `mediaplayer`, `mipns-xiaomi`, `mibrain`, Bluetooth, USB Audio, LED services, or other stock services.
- Do not synthesize Xiaomi PNS/LED lifecycle events merely to make AirPlay appear integrated.
- Runtime payload target: `/data/open-xiaoai/addons/airplay2/`.
- No Debian rootfs/chroot is shipped to the speaker.
- This PoC proves buildability, dependency size and deployability only. It does **not** claim AirPlay 2 works on OH2P until a real iPhone/macOS can discover it, connect, establish an AP2 session with working NQPTP timing, play audio, and stock Xiaomi capabilities recover afterwards.

## Known OH2P runtime facts

- Model: Xiaomi Smart Speaker Pro / OH2P
- Firmware: 1.62.2
- Kernel: Linux 4.9.61 / LEDE
- CPU: 4 x Cortex-A53 ~1.2 GHz
- Kernel architecture: aarch64
- Userspace ABI: 32-bit ARM hard-float (`/lib/ld-linux-armhf.so.3`)
- RAM: about 256 MB
- `/data` free space: about 117 MB
- Physical speaker PCM: ALSA card 0 device 2 (`TDM-C-acm8625p`), S16_LE, stereo, 48000 Hz
- Existing mDNS daemon: `mdnsd`
- No ffmpeg or avahi-daemon is known to be present
- root / SSH / `/data/init.sh` are available

## Stock OH2P ALSA graph

Read-only inspection of `/etc/asound.conf` on OH2P 1.62.2 shows that normal playback is not a bare `hw:0,2` path:

```text
default
  -> plug: force S16_LE / 48000
  -> vis (type file)
     -> safe_fifo
        -> /tmp/vis_audio.fifo
        -> /tmp/mis_audio.fifo
  -> tocopy
  -> Playback
     -> plug
     -> softvol
     -> dmixer
        -> dmix
        -> hw:0,2
```

The stock `dmixer` parameters are:

- format: S16_LE
- rate: 48000 Hz
- period_size: 480 frames = 10 ms
- buffer_size: 4800 frames = 100 ms

Therefore the PoC must **not** hard-code `hw:0,2` as the normal Shairport Sync target. Runtime launch must support a selectable ALSA PCM name, with the first hardware test order:

1. `default`
2. `Playback`
3. `dmixer`
4. `hw:0,2` only as a lowest-level direct/timing baseline

The four paths must be compared rather than declaring one winner in advance.

## Stock audio taps and visualizer path

The `default` route has verified stock audio taps rather than a theoretical plugin chain:

- `/tmp/vis_audio.fifo` is a real FIFO maintained by `safe_fifo`.
- `/tmp/mis_audio.fifo` is a real FIFO maintained by `safe_fifo`.
- `misound_service` reads `/tmp/mis_audio.fifo`.
- `/usr/bin/vis` references `/tmp/vis_audio.fifo` and contains `AudioSource`, `Visualizer`, `EllipseTransformer`, `mic audio receiver event`, `mic_audio UBus`, and `mic-audio` strings/components.
- The system also contains `/usr/sbin/ledd`, `pns_ubus_helper`, `mipns-xiaomi`, `misound_service`, and an LED UBus service.
- LED UBus methods observed include `show`, `shut`, `sleepmode`, `status`, and `loglevel`.

This makes `default` the most interesting first path for preserving Xiaomi's existing tap/softvol/dmix route. It does **not** prove that simply sending PCM through `default` will automatically trigger Xiaomi lighting or visualizer behaviour; LED/audio-focus state is also controlled by PNS, `mic_audio`, player state, and other Xiaomi services.

## Open-XiaoAI already validates ALSA `default`

The existing Open-XiaoAI client has already played successfully on the real OH2P through ALSA default using:

```text
aplay --quiet
  -t raw
  -f S16_LE
  -r 24000
  -c 1
  --buffer-size 4800
  --period-size 1200
  -
```

The parent process is `/data/open-xiaoai/client`. Although its input is 24 kHz mono S16_LE, the physical speaker PCM is 48 kHz stereo S16_LE. This is direct hardware evidence that the stock ALSA default graph can perform resampling, channel conversion, and shared playback on OH2P.

That evidence is the reason the Shairport PoC will test `default` first; it is not merely a desktop-ALSA assumption.

## `mipns-xiaomi` is a protected stock service

Read-only inspection shows `/usr/bin/mipns-xiaomi -c /usr/share/mipns/ -r opus32 -l` is a substantial Xiaomi audio/voice component (about 42 threads and roughly 22 MB RSS in the observed state). It opens:

- `pcmC0D3c` capture
- `pcmC0D2p` playback
- `controlC0`

Its binary contains ALSA operations including `snd_pcm_open`, `snd_pcm_writei`, `snd_pcm_readi`, `snd_pcm_drop`, `snd_pcm_drain`, `snd_pcm_prepare`, and Xiaomi-specific playback routines such as `mipns_playback_pcm_init`, `mipns_playback_pcm_open`, `mipns_playback_pcm_pre_write`, `mipns_playback_pcm_writei`, and `mipns_playback_pcm_after_write`.

The AirPlay PoC must not kill `mipns-xiaomi` to obtain exclusive `hw:0,2` access. Direct `hw:0,2` is only a manually selected diagnostic baseline and may conflict with stock audio users.

## Xiaomi TTS / PNS / LED lifecycle observation

This is recorded only for coexistence analysis; the AirPlay PoC must not modify Hermes/Open-XiaoAI Bridge or imitate these events automatically.

The stock `/usr/sbin/tts_play.sh` supports `-n` / `--notify-pns`, disabled by default. When enabled it issues:

```text
before playback:
ubus call pnshelper event_notify {"src":3,"event":14}

after playback:
ubus call pnshelper event_notify {"src":3,"event":15}
```

`pnshelper` exposes `event_notify(src,event,detail)`. This is evidence that Xiaomi playback/LED/focus state has an explicit lifecycle beyond the fact that PCM samples are flowing. The AirPlay PoC will not fabricate these notifications.

## Xiaomi `miplayer` observation

The stock `miplayer` executable supports `--file`, `--socket`, and `--loop`, links `libffmpeg-miplayer.so`, `libxiaomimediaplayerlite.so`, and `libcurl.so.4`, and contains routines including `async_prepare_play`, `play_url`, and `wait_play_finished`.

There is currently **no evidence** that `--socket` accepts raw PCM. Therefore no `Shairport -> miplayer socket` backend is assumed. If that route is investigated later, its Unix-socket protocol must be characterized independently first.

## Upstream AirPlay 2 requirements checked for this PoC

Current Shairport Sync upstream documentation requires AirPlay 2 builds to use:

- Shairport Sync built with `--with-airplay-2`
- NQPTP companion daemon for AirPlay 2 timing
- OpenSSL (`--with-ssl=openssl` is mandatory for AirPlay 2)
- Avahi (`--with-avahi` is mandatory for AirPlay 2)
- ALSA backend on OH2P
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

## Build/runtime result so far

The isolated GitHub Actions build has already proven that:

- Shairport Sync 5.0.4 with AirPlay 2 can be cross-compiled for armhf.
- NQPTP 1.2.8 can be cross-compiled for armhf.
- AirPlay 2 objects (`ap2_*` and PTP support) are present in the final Shairport link.
- A fail-closed `DT_NEEDED` runtime closure can be collected into `/data/open-xiaoai/addons/airplay2/`.
- The bundled `nqptp -V` and `shairport-sync -V` execute under qemu-arm using the bundled armhf loader and libraries.

These are build/runtime-bundle facts only, not OH2P AirPlay 2 functionality proof.

## OH2P-specific risks to validate

1. **ABI / libc compatibility**: the first artifact carries a Debian bullseye armhf loader/libc closure. QEMU startup succeeds, but real OH2P LEDE ABI interaction still needs device testing.
2. **mDNS**: AirPlay 2 uses Avahi in this standard backend. OH2P already runs Xiaomi `mdnsd`; coexistence on UDP 5353 and D-Bus behaviour must be checked on device. PoC scripts must refuse unsafe automatic takeover rather than killing stock mDNS.
3. **ALSA path selection**: first compare `default`, `Playback`, `dmixer`, then raw `hw:0,2`. Do not assume the direct hardware device is preferable.
4. **PTP ports**: UDP 319/320 must be free and usable by NQPTP.
5. **Audio format and latency**: each ALSA route must be checked for conversion behaviour, buffer latency, stability and PTP/multiroom timing.
6. **Memory/storage**: runtime RSS matters on a ~256 MB system even though the compressed artifact is small enough for `/data`.
7. **Stock coexistence**: XiaoAI wake/AEC/TTS, stock volume, Bluetooth/USB Audio, visualizer/LED state and recovery after AirPlay stop must be verified explicitly.

## ALSA comparison matrix for hardware phase

Compare the following routes without pre-selecting a winner:

```text
A: Shairport -> ALSA default -> Xiaomi audio taps -> softvol -> dmix -> hw:0,2
B: Shairport -> Playback -> softvol -> dmix -> hw:0,2
C: Shairport -> dmixer -> hw:0,2
D: Shairport -> hw:0,2
```

For each route record:

- AirPlay 2 discovery and connection
- AP2 session establishment
- NQPTP / PTP timing health
- actual audio output
- playback stability
- latency
- multiroom synchronization
- CPU and RSS
- XiaoAI wake/AEC/TTS behaviour
- stock volume control behaviour
- visualizer / LED observations (without injecting LED/PNS events)
- stock functionality recovery after stopping AirPlay

## Phase 1 deployable layout

The GitHub Actions artifact is laid out for:

```text
/data/open-xiaoai/addons/airplay2/
  bin/
    shairport-sync
    nqptp
    avahi-daemon
    dbus-daemon
  lib/
    ...runtime shared libraries...
  etc/
    shairport-sync.conf
    avahi-daemon.conf
    dbus-poc.conf
  scripts/
    check-oh2p.sh
    run-dbus.sh
    run-avahi.sh
    run-nqptp.sh
    run-shairport-sync.sh
  BUILD-INFO.txt
  DEPENDENCIES.txt
  SIZE-REPORT.txt
```

The artifact is deliberately self-contained under `/data`; deployment itself changes no rootfs files and does not install a Debian rootfs.

## Hardware-test safety rule

The first OH2P test must remain reversible:

- extract only under `/data/open-xiaoai/addons/airplay2/`
- do not modify `/data/init.sh`
- do not automatically stop Xiaomi services
- do not automatically operate LEDs
- inspect ports/processes first
- verify bundled binaries and loader first
- start PoC components manually and one at a time
- stop PoC processes to return to the pre-test state

Only a real end-to-end AirPlay 2 test can move the status beyond PoC.