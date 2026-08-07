#!/usr/bin/env python3
"""Connect to the XRCam stream and report what is actually arriving.

Splits a phone-side problem from an OBS-side one: if this shows a healthy
stream, the camera, encoder and iproxy bridge are all working and the fault
is in OBS configuration.

The app serves one client at a time -- do not run this while OBS is
connected, or the two will contend for the same socket.
"""

import argparse
import collections
import socket
import sys
import time

NAL_NAMES = {
    1: "non-IDR slice",
    5: "IDR (keyframe)",
    6: "SEI",
    7: "SPS",
    8: "PPS",
    9: "AUD",
}

START_CODE = b"\x00\x00\x00\x01"


AUD = b"\x00\x00\x00\x01\x09"


def cadence(host: str, port: int, seconds: float) -> int:
    """Measure per-frame arrival timing.

    Frames are delimited by the Access Unit Delimiter the app emits, so each
    AUD sighting timestamps one frame's arrival at the PC. If frames arrive at
    a steady ~33 ms with low jitter, the phone, encoder and iproxy are adding
    no meaningful delay — and any lag seen on screen lives in OBS.
    """
    sock = socket.socket()
    sock.settimeout(max(2.0, seconds + 2))
    sock.connect((host, port))

    arrivals = []
    tail = b""
    started = time.time()
    try:
        while time.time() - started < seconds:
            chunk = sock.recv(65536)
            if not chunk:
                break
            now = time.time()
            data = tail + chunk
            count = data.count(AUD)
            arrivals.extend([now] * count)
            tail = data[-8:]
    except socket.timeout:
        pass
    finally:
        sock.close()

    if len(arrivals) < 10:
        print(f"only {len(arrivals)} frames seen -- is the app streaming?")
        return 1

    gaps = [(b - a) * 1000 for a, b in zip(arrivals, arrivals[1:])]
    gaps_sorted = sorted(gaps)
    n = len(gaps_sorted)
    span = arrivals[-1] - arrivals[0]

    print(f"{len(arrivals)} frames in {span:.1f}s  ->  {(len(arrivals)-1)/span:.1f} fps effective")
    print()
    print("inter-frame arrival gaps (target ~33 ms at 30fps):")
    print(f"  median  {gaps_sorted[n // 2]:6.1f} ms")
    print(f"  p90     {gaps_sorted[int(n * 0.90)]:6.1f} ms")
    print(f"  p99     {gaps_sorted[min(n - 1, int(n * 0.99))]:6.1f} ms")
    print(f"  worst   {gaps_sorted[-1]:6.1f} ms")
    print()

    steady = gaps_sorted[n // 2] < 45 and gaps_sorted[int(n * 0.90)] < 70
    if steady:
        print("UPSTREAM CLEAN -- frames reach this machine on schedule.")
        print("Any lag visible on screen is added by OBS, not the phone or the cable.")
    else:
        print("*** frames arrive in bursts -- delay is upstream of OBS ***")
    return 0 if steady else 1


def capture(host: str, port: int, seconds: float) -> bytes:
    sock = socket.socket()
    sock.settimeout(max(2.0, seconds + 2))
    sock.connect((host, port))

    buf = bytearray()
    started = time.time()
    try:
        while time.time() - started < seconds:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        pass
    finally:
        sock.close()

    return bytes(buf)


def analyse(buf: bytes, elapsed: float) -> bool:
    counts = collections.Counter()
    offset = 0
    while True:
        found = buf.find(START_CODE, offset)
        if found < 0:
            break
        if found + 4 < len(buf):
            counts[buf[found + 4] & 0x1F] += 1
        offset = found + 4

    mbps = len(buf) * 8 / elapsed / 1e6 if elapsed else 0
    print(f"captured {len(buf)/1024:.0f} KiB in {elapsed:.1f}s  ->  {mbps:.1f} Mb/s")
    print()
    print("NAL unit histogram:")
    for nal_type, count in sorted(counts.items()):
        name = NAL_NAMES.get(nal_type, "other")
        print(f"  type {nal_type:<2} {name:<16} x{count}")

    slices = counts[1] + counts[5]
    print()
    print(f"  ~{slices/elapsed:.0f} frames/sec, {counts[5]} keyframes")

    healthy = counts[7] > 0 and counts[8] > 0 and counts[5] > 0
    print()
    if healthy:
        print("STREAM VALID -- SPS, PPS and IDR all present.")
        print("If OBS still shows nothing, check that Input Format is set to 'h264'.")
    else:
        print("*** INCOMPLETE -- missing parameter sets or keyframes ***")
    return healthy


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--seconds", type=float, default=4.0)
    parser.add_argument("--cadence", action="store_true",
                        help="measure per-frame arrival timing instead of "
                             "stream structure")
    args = parser.parse_args()

    if args.cadence:
        try:
            return cadence(args.host, args.port, max(args.seconds, 8.0))
        except ConnectionRefusedError:
            print(f"Connection refused on {args.host}:{args.port}.")
            print("Is iproxy running, and is XRCam started on the phone?")
            return 1
        except OSError as exc:
            print(f"Could not connect: {exc}")
            return 1

    try:
        started = time.time()
        buf = capture(args.host, args.port, args.seconds)
        elapsed = time.time() - started
    except ConnectionRefusedError:
        print(f"Connection refused on {args.host}:{args.port}.")
        print("Is iproxy running, and is XRCam started on the phone?")
        return 1
    except OSError as exc:
        print(f"Could not connect: {exc}")
        return 1

    if not buf:
        print("Connected but received no data -- is the app streaming?")
        return 1

    return 0 if analyse(buf, elapsed) else 1


if __name__ == "__main__":
    sys.exit(main())
