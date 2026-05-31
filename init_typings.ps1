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

# 3) ThingsBoard SDK Core (sdk_core – Submodul von thingsboard-micropython-client-sdk)
#    Pylance-Default-Stubpath ist "typings/", deshalb genuegt typings/sdk_core/ damit
#    "from sdk_core.device_mqtt import TBDeviceMqttClientBase" aufgeloest werden kann.
Write-Host "==> Lade thingsboard-micro-sdk-core von GitHub ..."
Invoke-WebRequest `
    -Uri "https://github.com/thingsboard/thingsboard-micro-sdk-core/archive/refs/heads/main.zip" `
    -OutFile "tb_sdk_core.zip"
Expand-Archive "tb_sdk_core.zip" -DestinationPath "tb_sdk_core_temp" -Force
$sdkCoreSrc = "tb_sdk_core_temp\thingsboard-micro-sdk-core-main"
$sdkCoreDst = "typings\sdk_core"
if (Test-Path $sdkCoreDst) {
    Remove-Item -Recurse -Force $sdkCoreDst
}
New-Item -ItemType Directory -Path $sdkCoreDst | Out-Null
Copy-Item "$sdkCoreSrc\*" $sdkCoreDst -Recurse
# __init__.py benoetigt damit Python es als Package erkennt
if (-not (Test-Path "$sdkCoreDst\__init__.py")) {
    New-Item -ItemType File -Path "$sdkCoreDst\__init__.py" | Out-Null
}
Remove-Item -Recurse -Force "tb_sdk_core.zip", "tb_sdk_core_temp"

Write-Host ""
Write-Host "Fertig. typings/ ist aktuell."
