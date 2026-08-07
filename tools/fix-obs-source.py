#!/usr/bin/env python3
"""Write the low-latency XRCam settings directly into the OBS scene JSON.

The Properties dialog has silently dropped these edits more than once, so
this bypasses it. OBS must be FULLY CLOSED when this runs -- it rewrites
scene files from memory on exit and would clobber the edit.

A timestamped backup of the scene file is made before anything is written.
"""

import json
import shutil
import sys
import time
from pathlib import Path

SCENE = Path.home() / "AppData/Roaming/obs-studio/basic/scenes/Microphone_Only.json"
SOURCE_NAME = "XRCam"

SETTINGS = {
    "input": "tcp://127.0.0.1:9000",
    "input_format": "h264",  # exact -- a trailing space breaks format lookup
    "ffmpeg_options": (
        "framerate=30 probesize=32 analyzeduration=0 "
        "fflags=nobuffer flags=low_delay use_wallclock_as_timestamps=1"
    ),
    "buffering_mb": 0,
    "hw_decode": False,
    "is_local_file": False,
    "restart_on_activate": True,
}


def obs_running() -> bool:
    import subprocess
    out = subprocess.run(
        ["tasklist", "/FI", "IMAGENAME eq obs64.exe"],
        capture_output=True, text=True,
    ).stdout
    return "obs64.exe" in out


def main() -> int:
    if obs_running():
        print("OBS is still running -- close it completely first, then rerun.")
        return 1

    if not SCENE.exists():
        print(f"Scene file not found: {SCENE}")
        return 1

    backup = SCENE.with_name(SCENE.name + ".bak-" + time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(SCENE, backup)
    print(f"backup written: {backup.name}")

    data = json.loads(SCENE.read_text(encoding="utf-8"))
    for source in data.get("sources", []):
        if source.get("id") == "ffmpeg_source" and source.get("name") == SOURCE_NAME:
            source.setdefault("settings", {}).update(SETTINGS)
            print(f"[{SOURCE_NAME}] updated:")
            for key, value in SETTINGS.items():
                print(f"  {key:<20} = {value!r}")
            SCENE.write_text(json.dumps(data), encoding="utf-8")
            print("SAVED -- reopen OBS.")
            return 0

    print(f"No ffmpeg_source named {SOURCE_NAME!r} found -- nothing written.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
