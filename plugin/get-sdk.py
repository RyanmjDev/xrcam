#!/usr/bin/env python3
"""Fetch what building the OBS plugin needs. Run once (and after OBS upgrades).

Produces, under plugin/sdk/ (gitignored):
  libobs/           headers from the obs-studio release matching the install
  config/obsconfig.h  minimal stub (normally CMake-generated)
  obs.lib           import library derived from the installed obs.dll

The import library trick: link against the exact DLL the user runs, so there
is no separate "OBS SDK" to version-match -- dumpbin lists obs.dll's exports,
lib.exe turns that list into a .lib.
"""

import io
import re
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SDK = HERE / "sdk"
OBS_DLL = Path(r"C:\Program Files\obs-studio\bin\64bit\obs.dll")
VSWHERE = Path(r"C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe")


def obs_version() -> str:
    out = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         f"(Get-Item '{OBS_DLL}').VersionInfo.ProductVersion"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", out):
        sys.exit(f"unexpected OBS version string: {out!r}")
    return out


def fetch_headers(version: str) -> None:
    dest = SDK / "libobs"
    if (dest / "obs-module.h").exists():
        print(f"headers already present: {dest}")
        return

    url = f"https://github.com/obsproject/obs-studio/archive/refs/tags/{version}.zip"
    print(f"downloading {url} ...")
    data = urllib.request.urlopen(url, timeout=120).read()
    print(f"  {len(data)//1024//1024} MiB")

    prefix = f"obs-studio-{version}/libobs/"
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        names = [n for n in z.namelist()
                 if n.startswith(prefix) and not n.endswith("/")]
        for name in names:
            rel = name[len(prefix):]
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(z.read(name))
    print(f"extracted {len(names)} files -> {dest}")


def write_obsconfig(version: str) -> None:
    cfg = SDK / "config" / "obsconfig.h"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    major = version.split(".")[0]
    cfg.write_text(f"""#pragma once
/* Minimal stand-in for the CMake-generated obsconfig.h -- only what the
 * public headers actually reference when compiling an external plugin. */
#define OBS_VERSION "{version}"
#define OBS_VERSION_CANONICAL "{version}"
#define LIBOBS_API_MAJOR_VER {major}
#define OBS_DATA_PATH "../../data"
#define OBS_INSTALL_PREFIX ""
#define OBS_PLUGIN_DESTINATION "obs-plugins/64bit"
#define OBS_RELATIVE_PREFIX "../../"
#define OBS_RELEASE_CANDIDATE 0
#define OBS_BETA 0
""", encoding="utf-8")
    print(f"wrote {cfg}")


def msvc_tool(name: str) -> Path:
    vsroot = subprocess.run(
        [str(VSWHERE), "-latest", "-products", "*",
         "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
         "-property", "installationPath"],
        capture_output=True, text=True, check=True,
    ).stdout.strip().splitlines()[0]
    tools = sorted((Path(vsroot) / "VC/Tools/MSVC").iterdir())[-1]
    exe = tools / "bin/Hostx64/x64" / name
    if not exe.exists():
        sys.exit(f"{name} not found under {tools}")
    return exe


def make_import_lib() -> None:
    out = SDK / "obs.lib"
    if out.exists():
        print(f"import lib already present: {out}")
        return

    dumpbin = msvc_tool("dumpbin.exe")
    libexe = msvc_tool("lib.exe")

    exports = subprocess.run(
        [str(dumpbin), "/exports", str(OBS_DLL)],
        capture_output=True, text=True, check=True,
    ).stdout

    # dumpbin export rows: "ordinal  hint  RVA  name"
    names = []
    for line in exports.splitlines():
        m = re.match(r"\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)", line)
        if m:
            names.append(m.group(1))
    if len(names) < 100:
        sys.exit(f"only {len(names)} exports parsed -- dumpbin format changed?")

    deffile = SDK / "obs.def"
    deffile.write_text("LIBRARY obs\nEXPORTS\n" +
                       "\n".join(names) + "\n", encoding="utf-8")

    subprocess.run(
        [str(libexe), f"/def:{deffile}", "/machine:x64", f"/out:{out}",
         "/nologo"],
        check=True,
    )
    print(f"wrote {out} ({len(names)} exports)")


def main() -> int:
    if not OBS_DLL.exists():
        sys.exit(f"OBS not found at {OBS_DLL}")
    version = obs_version()
    print(f"OBS {version}")
    SDK.mkdir(exist_ok=True)
    fetch_headers(version)
    write_obsconfig(version)
    make_import_lib()
    print("SDK ready.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
