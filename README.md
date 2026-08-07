# XRCam

Turn an iPhone XR into a low-latency 4K camera source for OBS on Windows, over USB.

Built entirely without a Mac: authored on Windows, compiled on a GitHub Actions
macOS runner, installed via Sideloadly.

**Current status: M0 — toolchain proof.** The app displays build and device
diagnostics and verifies the camera reports a 4K30 format. It does not yet
capture or stream. See [the plan](../../.claude/plans) for the full milestone list.

---

## How it will work

```
iPhone XR                              Windows PC
─────────                              ──────────
AVCaptureSession (4K30)
  ├─ VTCompressionSession (H.264)
  │    └─ Annex-B NALs
  │         └─ TCP listener :9000  ──USB──▶  iproxy 9000:9000
  │                                              │
  │                                              ▼
  │                                    OBS Media Source
  │                                    tcp://127.0.0.1:9000
  │                                              │
  └─ AVAssetWriter → local .mov master           ▼
                                        Virtual Camera / RTMP
```

The Windows side needs no custom software — `iproxy` is one command and OBS
ingests `tcp://` natively.

---

## Windows prerequisites

| Tool | Purpose |
|---|---|
| [Apple Mobile Device Support](https://www.apple.com/itunes/) (ships with iTunes) | Provides usbmuxd, the USB multiplexer |
| [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) (Windows build) | Provides `iproxy` — add to `PATH` |
| [Sideloadly](https://sideloadly.io/) | Signs and installs the unsigned IPA |
| [OBS Studio 28+](https://obsproject.com/) | Version 28 added the Media Source "FFmpeg Options" field |

---

## Build and install loop

There is no iOS Simulator on Windows, so every change goes through CI. Measured
turnaround is **~30 seconds** of runner time (14s of that is the actual compile),
plus however long the job waits for a free macOS runner. The wait, not the build,
is what varies.

1. **Push to `main`** (or trigger *Build unsigned IPA* manually from the Actions tab).
2. **Download the `XRCam-ipa` artifact** from the completed run.
3. **Unzip it** — the artifact is a zip *containing* `XRCam.ipa`.
4. **Open Sideloadly**, drag in `XRCam.ipa`, enter your Apple ID, click Start.
5. On first install only: **Settings → General → VPN & Device Management** on the
   phone, and trust the developer certificate.

> **Free Apple ID caveat:** the certificate expires after 7 days and you may have
> at most 3 sideloaded apps at once. Repeat step 4 to refresh. The $99/yr Apple
> Developer Program raises this to a year.

The app's **Built** timestamp is shown on screen — check it after installing to
confirm you are looking at the new build and not a stale one.

### CI cost

macOS runners bill at a **10× multiplier**. A public repo gets unlimited free
minutes; a private repo on the free plan effectively gets ~200 macOS minutes per
month. The workflow cancels superseded runs to avoid wasting them.

---

## OBS setup (from M1 onward)

1. Connect the iPhone by cable and launch XRCam.
2. Run `tools\start-bridge.bat` and leave the window open.
3. In OBS: **Sources → + → Media Source**
   - Uncheck **Local File**
   - **Input:** `tcp://127.0.0.1:9000`
   - **Input Format:** `h264`
   - **FFmpeg Options:** `framerate=30 probesize=32 analyzeduration=0 fflags=nobuffer flags=low_delay use_wallclock_as_timestamps=1`
   - **Network Buffering:** `0 MB`
   - **Use hardware decoding when available:** **unchecked**
   - Check **Restart playback when source becomes active**

### Latency

Out of the box OBS buffers network sources heavily — its default network
buffering alone is seconds of delay, and ffmpeg adds more while it probes the
stream. The extra FFmpeg options above matter as much as the URL:

| Option | Effect |
|---|---|
| `probesize=32` | Stop inspecting the stream after 32 bytes |
| `analyzeduration=0` | Do not spend wall-clock time analysing before playback |
| `fflags=nobuffer` | Do not buffer frames internally |
| `flags=low_delay` | Ask the decoder not to hold frames back |
| `use_wallclock_as_timestamps=1` | Stamp frames with their **arrival time** |

`use_wallclock_as_timestamps=1` deserves explanation, because it targets a
failure mode the others do not: a **constant** delay that never drains. A raw
elementary stream has no timestamps, so ffmpeg synthesizes them from
`framerate`, counting from the first packet. Any data sitting in the pipeline
when playback starts (TCP socket buffers on both machines, iproxy's internal
buffer) then becomes a permanent offset — OBS renders every frame exactly that
far behind forever, and no later option can claw it back. Wallclock stamping
ties each frame to when it actually arrived instead, so OBS renders it
immediately.

Hardware decoding is unchecked because GPU decoders queue several frames
internally; for a no-B-frame stream, software decode of 4K30 is light work
and shaves the queue.

**Network Buffering is a separate slider from the FFmpeg options** and must
be `0 MB`.

### Unbuffered rendering

OBS holds every decoded frame until its timestamp comes due, with smoothing
on top — correct for file playback, pure latency for a live camera. Load
`tools/xrcam-unbuffered.lua` via **Tools → Scripts → +** to flip the XRCam
source to unbuffered rendering (newest frame shown immediately). Webcam
sources expose this as a checkbox; the Media Source only allows it through
the scripting API.

### Locating remaining lag

```bash
python tools/probe-stream.py --cadence
```

(Disable the OBS source first — eye icon off — the app serves one client at a
time.) This timestamps every frame's arrival at the PC. If the median gap is
~33 ms with low jitter, the phone, encoder, cable and iproxy are delivering on
schedule and **any residual lag is inside OBS** — the reverse means the delay
is upstream. This is the measurement to take before touching any more
settings.

**`Input Format` is not optional.** The stream is a raw H.264 elementary
stream — no container, no header — so ffmpeg cannot probe what it is
receiving. Left blank, OBS connects, fails to identify the format, and
closes the socket. From the phone that is indistinguishable from OBS never
having connected at all.

Two other things that produce the same silent symptom:

- The media source must be **in the active scene and visible**. OBS does not
  open a source it is not rendering, so it never dials out.
- The phone must be listening **before** OBS opens the source, or ffmpeg gets
  connection-refused and gives up.

### Verifying the stream without OBS

To tell a phone-side problem from an OBS-side one, connect directly:

```bash
python tools/probe-stream.py
```

It reports throughput and a NAL histogram. A healthy 1080p30 stream shows
~12 Mb/s, ~30 slices/second, and an `SPS → PPS → SEI → IDR` group every two
seconds. If that looks right, the phone, the encoder and `iproxy` are all
fine and the problem is in OBS.

Note the app serves **one client at a time** — do not run the probe while OBS
is connected, or they will contend for the same socket.

---

## Repo layout

```
project.yml                  XcodeGen manifest — the .xcodeproj is generated, never committed
.github/workflows/build.yml  macOS CI → unsigned .ipa artifact
tools/start-bridge.bat       iproxy USB bridge
Sources/App/                 SwiftUI entry point and M0 diagnostics
```

`XRCam.xcodeproj` is intentionally absent — it is regenerated from `project.yml`
by CI on every build, which is what makes Windows-only authoring possible.
