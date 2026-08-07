@echo off
setlocal
REM Builds xrcam-source.dll and installs it into the per-user OBS plugin
REM directory (no admin needed). Run plugin\get-sdk.py once first.

cd /d "%~dp0"

if not exist sdk\obs.lib (
    echo [!] sdk\obs.lib missing -- run:  python get-sdk.py
    exit /b 1
)

REM Locate VS and enter an x64 build environment.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%i"
if not defined VSROOT (
    echo [!] Visual Studio with C++ tools not found.
    exit /b 1
)
call "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat" >nul

cl /nologo /std:c17 /W3 /O2 /MD /LD ^
   /Isdk\libobs /Isdk\config ^
   xrcam-source.c ^
   /Fe:xrcam-source.dll ^
   /link sdk\obs.lib
if errorlevel 1 exit /b 1

set "DEST=%APPDATA%\obs-studio\plugins\xrcam-source\bin\64bit"
if not exist "%DEST%" mkdir "%DEST%"

REM OBS locks the DLL while running; a failed copy here means close OBS first.
copy /y xrcam-source.dll "%DEST%\xrcam-source.dll" >nul
if errorlevel 1 (
    echo [!] Could not install -- is OBS running? Close it and rerun.
    exit /b 1
)

echo Installed: %DEST%\xrcam-source.dll
echo Restart OBS, then add source: "XRCam USB Camera"
