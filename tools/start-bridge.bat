@echo off
REM ---------------------------------------------------------------------------
REM Bridges the tethered iPhone to Windows localhost over USB.
REM
REM iproxy forwards a local TCP port to a port the *phone* is listening on,
REM so XRCam must be running and listening before OBS opens its source.
REM
REM Chain:  OBS -> tcp://127.0.0.1:9000 -> iproxy -> usbmuxd -> XRCam
REM ---------------------------------------------------------------------------

where iproxy >nul 2>&1
if errorlevel 1 (
    echo [!] iproxy not found on PATH.
    echo     Install libimobiledevice for Windows and add its folder to PATH.
    echo     Apple Mobile Device Support ^(bundled with iTunes^) must also be installed.
    exit /b 1
)

echo Forwarding 127.0.0.1:9000 -^> iPhone:9000
echo Leave this window open. Ctrl+C to stop.
echo.

REM Older libimobiledevice builds use "iproxy 9000 9000" instead.
iproxy 9000:9000
