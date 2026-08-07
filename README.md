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
   - **FFmpeg Options:** `framerate=30`
   - Check **Restart playback when source becomes active**

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
