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
    args = parser.parse_args()

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
