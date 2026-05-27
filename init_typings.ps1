# init_typings.ps1
# Richtet das typings/-Verzeichnis fuer MicroPython (Pico 2 W) ein.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Sicherstellen, dass das typings/-Verzeichnis existiert
if (-not (Test-Path "typings")) {
    New-Item -ItemType Directory -Path "typings" | Out-Null
}

# 1) MicroPython RP2 Pico 2 W Stubs
Write-Host "==> Installiere micropython-rp2-rpi_pico2_w-stubs ..."
pip install micropython-rp2-rpi_pico2_w-stubs --target typings --no-user

# 2) ThingsBoard MicroPython SDK
Write-Host "==> Lade thingsboard-micropython-client-sdk von GitHub ..."
Invoke-WebRequest `
    -Uri "https://github.com/thingsboard/thingsboard-micropython-client-sdk/archive/refs/heads/main.zip" `
    -OutFile "tb_sdk.zip"
Expand-Archive "tb_sdk.zip" -DestinationPath "tb_sdk_temp" -Force
$sdkSrc = "tb_sdk_temp\thingsboard-micropython-client-sdk-main\thingsboard_sdk"
$sdkDst = "typings\thingsboard_sdk"
if (Test-Path $sdkDst) {
    Remove-Item -Recurse -Force $sdkDst
}
Copy-Item -Recurse $sdkSrc $sdkDst
Remove-Item -Recurse -Force "tb_sdk.zip", "tb_sdk_temp"

Write-Host ""
Write-Host "Fertig. typings/ ist aktuell."
