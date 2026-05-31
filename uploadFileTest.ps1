# uploadFileTest.ps1
# Testet den uploadFile-RPC manuell ueber die ThingsBoard REST-API.
# Schickt eine Testdatei an das Geraet mit der fest hinterlegten Device-ID.
#
# Zweck:    Debuggen des RPC-Pfads ohne Widget oder laufenden Pico.
#           Setzt einen laufenden Testclient (oder Pico) voraus, der auf RPCs wartet.
#
# Aufruf:   .\uploadFileTest.ps1
#           -> fragt ThingsBoard-Benutzername und Passwort interaktiv ab

# Erst ThingsBoard Login-Token holen
$envMap = @{}
Get-Content (Join-Path $PSScriptRoot ".env") | Where-Object { $_ -match "^[^#]+=.+" } |
    ForEach-Object { $k, $v = $_ -split "=", 2; $envMap[$k.Trim()] = $v.Trim() }
$tbUser = $envMap["THINGSBOARD_USERNAME"]
if (-not $tbUser) { $tbUser = Read-Host "ThingsBoard Benutzer" }
Write-Host "Login als $tbUser"

$tbPass = Read-Host "Passwort" -AsSecureString
$tbPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tbPass))
$login = Invoke-RestMethod -Uri "http://thingsboard:8080/api/auth/login" `
    -Method POST -ContentType "application/json" `
    -Body "{`"username`":`"$tbUser`",`"password`":`"$tbPassPlain`"}"

# 2FA: ThingsBoard gibt token mit scope=PRE_VERIFICATION_TOKEN zurueck
if ($login.scope -eq "PRE_VERIFICATION_TOKEN") {
    $totpCode = Read-Host "2FA-Code (TOTP)"
    $mfaCheck = Invoke-RestMethod -Uri "http://thingsboard:8080/api/auth/2fa/verification/check?providerType=TOTP&verificationCode=$totpCode" `
        -Method POST `
        -Headers @{ Authorization = "Bearer $($login.token)" } `
        -ErrorAction Stop
    $jwt = $mfaCheck.token
} else {
    $jwt = $login.token
}

if (-not $jwt) {
    Write-Error "Kein JWT erhalten. Login-Response: $($login | ConvertTo-Json)"
    exit 1
}
Write-Host "JWT erhalten (erste 20 Zeichen): $($jwt.Substring(0,20))..."

# Device-ID des Testclient-Geräts (aus ThingsBoard UI kopieren)
$deviceId = "ec870240-5c86-11f1-92d9-93754c56e8e7"

# uploadFile RPC senden
Invoke-RestMethod -Uri "http://thingsboard:8080/api/rpc/twoway/$deviceId" `
    -Method POST -ContentType "application/json" `
    -Headers @{Authorization="Bearer $jwt"} `
    -Body '{"method":"uploadFile","params":{"filename":"test.py","content":"print(\"hello\")"},"timeout":10000}' `
    -ErrorAction Stop