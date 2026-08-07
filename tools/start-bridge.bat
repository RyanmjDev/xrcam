@echo off
setlocal
REM ---------------------------------------------------------------------------
REM Bridges the tethered iPhone to Windows localhost over USB.
REM
REM iproxy forwards a local TCP port to a port the *phone* is listening on,
REM so XRCam must be running and listening before OBS opens its source.
REM
REM Chain:  OBS -> tcp://127.0.0.1:9000 -> iproxy -> usbmuxd -> XRCam
REM ---------------------------------------------------------------------------

set "IPROXY="

REM 1. Prefer whatever is on PATH.
where iproxy >nul 2>&1
if not errorlevel 1 set "IPROXY=iproxy"

REM 2. Fall back to a stock MSYS2 install, so PATH never has to be edited.
if not defined IPROXY (
    for %%P in (
        "C:\msys64\mingw64\bin\iproxy.exe"
        "C:\msys64\usr\bin\iproxy.exe"
        "C:\msys32\mingw32\bin\iproxy.exe"
    ) do (
        if exist %%P set "IPROXY=%%~P"
    )
)

if not defined IPROXY (
    echo [!] iproxy not found.
    echo.
    echo     Install it with:
    echo         winget install MSYS2.MSYS2
    echo         C:\msys64\usr\bin\bash.exe -lc "pacman -S --noconfirm mingw-w64-x86_64-libusbmuxd"
    echo.
    echo     Apple Mobile Device Support ^(bundled with iTunes^) must also be
    echo     installed -- it provides usbmuxd. That part is already done.
    exit /b 1
)

echo Using: %IPROXY%
echo Forwarding 127.0.0.1:9000 -^> iPhone:9000
echo Leave this window open. Ctrl+C to stop.
echo.

REM Older libimobiledevice builds want "iproxy 9000 9000" instead of the
REM colon form, so fall back automatically rather than fail confusingly.
"%IPROXY%" 9000:9000
if errorlevel 1 (
    echo.
    echo [i] Retrying with legacy argument form...
    "%IPROXY%" 9000 9000
)
