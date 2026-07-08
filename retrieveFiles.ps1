# retrieveFiles.ps1
# Laedt alle Dateien eines Pico-Geraets per ThingsBoard-RPC (listFiles + downloadFile)
# in ein Zielverzeichnis herunter. Struktur (z. B. lib/...) wird beibehalten.
#
# Zweck:    Backup / Inspektion des tatsaechlich auf dem Geraet laufenden Codes.
#
# Aufruf:   .\retrieveFiles.ps1 -Destination ".\backup" -DeviceNr DEV
#           .\retrieveFiles.ps1 -o ".\backup" -n 1
#           .\retrieveFiles.ps1 -o ".\backup" -d "uuid"
#           .\retrieveFiles.ps1 -o ".\backup" -l "SMD-Kuehlschrank"
#           .\retrieveFiles.ps1 -o ".\backup" -n DEV -Exclude "/lib/*"   (SDK ueberspringen)

param(
    [Parameter(Mandatory = $true)]
    [Alias("o")]
    [string]$Destination,
    [Alias("d")]
    [string]$DeviceId = "",
    [Alias("n")]
    [string]$DeviceNr = "",
    [Alias("l")]
    [string]$Location = "",
    [Alias("p")]
    [string]$Path = "/",
    [string[]]$Exclude = @(),
    [switch]$NoRecursive,
    [int]$ChunkSize = 256
)

$ErrorActionPreference = "Stop"

# ── Root .env laden ────────────────────────────────────────────────────────────
$rootEnvFile = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path $rootEnvFile)) {
    Write-Error ".env nicht gefunden: $rootEnvFile"
    exit 1
}
$envMap = @{}
Get-Content $rootEnvFile | Where-Object { $_ -match "^[^#]+=.+" } |
    ForEach-Object { $k, $v = $_ -split "=", 2; $envMap[$k.Trim()] = $v.Trim() }

$baseUrl        = $envMap["THINGSBOARD_BASE_URL"]
$loginUrl       = $baseUrl + $envMap["THINGSBOARD_LOGIN_PATH"]
$rpcPath        = $envMap["THINGSBOARD_RPC_PATH"]
$userUrl        = $baseUrl + $envMap["THINGSBOARD_USER_PATH"]
$verifyPath     = $envMap["THINGSBOARD_VERIFY_PATH"]
$deviceInfoUrl  = $baseUrl + $envMap["THINGSBOARD_DEVICE_INFO_PATH"]
$deviceAttrPath = $envMap["THINGSBOARD_DEVICE_ATTRIBUTE_PATH"]
$tbUser         = $envMap["THINGSBOARD_USERNAME"]

if (-not $baseUrl) { Write-Error "THINGSBOARD_BASE_URL fehlt in .env"; exit 1 }
if (-not $rpcPath) { Write-Error "THINGSBOARD_RPC_PATH fehlt in .env"; exit 1 }

# ── Geraet aufloesen (Nr -> ID/Location) ───────────────────────────────────────
if ($DeviceNr) {
    $nr = $DeviceNr.ToUpper()
    if ($envMap["DEVICE_ID_$nr"])       { $DeviceId = $envMap["DEVICE_ID_$nr"] }
    if ($envMap["DEVICE_LOCATION_$nr"]) { $Location = $envMap["DEVICE_LOCATION_$nr"] }
    if (-not $DeviceId) { Write-Error "DEVICE_ID_$nr nicht in .env gefunden."; exit 1 }
    Write-Host "DeviceNr $nr -> $Location ($DeviceId)"
}

# ── JWT-Login (Cache + 2FA), analog deploy.ps1 ──────────────────────────────────
function Get-JwtExpiry([string]$token) {
    try {
        $payload = $token.Split('.')[1]
        $pad = 4 - ($payload.Length % 4); if ($pad -ne 4) { $payload += '=' * $pad }
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        return ($json | ConvertFrom-Json).exp
    } catch { return 0 }
}

if (-not $tbUser) { $tbUser = Read-Host "ThingsBoard Benutzer" }
$cacheFile = Join-Path $env:TEMP "tb_jwt_$($tbUser -replace '[^a-zA-Z0-9]','_').json"

$headers = $null
if (Test-Path $cacheFile) {
    $cached = Get-Content $cacheFile | ConvertFrom-Json
    $expiry = Get-JwtExpiry $cached.token
    $nowEpoch = [int][double]::Parse((Get-Date -UFormat %s))
    if ($expiry -gt ($nowEpoch + 60)) {
        Write-Host "Verwende gecachtes JWT-Token (gueltig bis $([DateTimeOffset]::FromUnixTimeSeconds($expiry).LocalDateTime))..."
        $headers = @{ Authorization = "Bearer $($cached.token)" }
        try {
            Invoke-RestMethod -Uri $userUrl -Headers $headers -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning "Gecachtes Token abgelaufen - neu anmelden."
            $headers = $null
        }
    } else {
        Write-Host "Gecachtes JWT-Token abgelaufen - neu anmelden."
    }
}

if (-not $headers) {
    $tbPass = Read-Host "Passwort fuer $tbUser" -AsSecureString
    if (-not $tbPass -or $tbPass.Length -eq 0) { Write-Error "Kein Passwort eingegeben. Abbruch."; exit 1 }
    $tbPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tbPass))

    try {
        $login = Invoke-RestMethod -Uri $loginUrl `
            -Method POST -ContentType "application/json" `
            -Body "{`"username`":`"$tbUser`",`"password`":`"$tbPassPlain`"}" `
            -ErrorAction Stop
    } catch { Write-Error "Login fehlgeschlagen: $_"; exit 1 }

    if ($login.scope -eq "PRE_VERIFICATION_TOKEN") {
        $totpCode = Read-Host "2FA-Code (TOTP)"
        try {
            $verifyUrl = $baseUrl + ($verifyPath -replace '%s', $totpCode)
            $mfaCheck = Invoke-RestMethod -Uri $verifyUrl `
                -Method POST -Headers @{ Authorization = "Bearer $($login.token)" } -ErrorAction Stop
        } catch { Write-Error "2FA-Verifikation fehlgeschlagen: $_"; exit 1 }
        $jwt = $mfaCheck.token
    } elseif ($login.token) {
        $jwt = $login.token
    } else {
        Write-Error "Login-Response enthaelt kein token. Abbruch."; exit 1
    }

    $headers = @{ Authorization = "Bearer $jwt" }
    @{ token = $jwt } | ConvertTo-Json | Set-Content $cacheFile
    Write-Host "Login erfolgreich. Token gecacht in $cacheFile"
}

# ── DeviceId per Location-Attribut nachschlagen, falls noetig ────────────────────
function Resolve-DeviceId {
    param([string]$Location, [hashtable]$Headers, [string]$BaseUrl, [string]$DeviceInfoUrl, [string]$DeviceAttrPath)
    $resp = Invoke-RestMethod -Uri $DeviceInfoUrl -Headers $Headers -ErrorAction Stop
    $devices = $resp.data | Where-Object { $_.deviceProfileName -eq "PicoData" }
    foreach ($device in $devices) {
        $attrUrl = $BaseUrl + ($DeviceAttrPath -replace '%s', $device.id.id)
        $attrs = Invoke-RestMethod -Uri $attrUrl -Headers $Headers -ErrorAction SilentlyContinue
        $locationAttr = $attrs | Where-Object { $_.key -eq "location" }
        if ($locationAttr -and $locationAttr.value -eq $Location) {
            Write-Host "Geraet gefunden: $($device.name) ($($device.id.id))"
            return $device.id.id
        }
    }
    return $null
}

if (-not $DeviceId) {
    if (-not $Location) { Write-Error "Bitte -DeviceId, -DeviceNr oder -Location angeben."; exit 1 }
    Write-Host "Suche Geraet mit location='$Location'..."
    $DeviceId = Resolve-DeviceId -Location $Location -Headers $headers -BaseUrl $baseUrl -DeviceInfoUrl $deviceInfoUrl -DeviceAttrPath $deviceAttrPath
    if (-not $DeviceId) { Write-Error "Kein PicoData-Geraet mit location='$Location' gefunden."; exit 1 }
}

$rpcUrl = $baseUrl + ($rpcPath -replace '%s', $DeviceId)

function Invoke-Rpc {
    param([hashtable]$Body)
    $json = ($Body | ConvertTo-Json -Depth 6 -Compress)
    return Invoke-RestMethod -Uri $rpcUrl -Method POST -ContentType "application/json" `
        -Headers $headers -Body $json -ErrorAction Stop
}

# ── 1) Dateiliste vom Geraet holen ──────────────────────────────────────────────
Write-Host "Frage Dateiliste an ($Path, recursive=$(-not $NoRecursive))..."
$listResp = Invoke-Rpc @{ method = "listFiles"; params = @{ path = $Path; recursive = (-not $NoRecursive) }; timeout = 15000 }
if (-not $listResp.success) { Write-Error "listFiles fehlgeschlagen: $($listResp.error)"; exit 1 }

$listJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($listResp.files_b64))
$files = @($listJson | ConvertFrom-Json)
Write-Host "$($files.Count) Datei(en) auf dem Geraet gefunden."

# Exclude-Filter anwenden (Wildcards gegen den vollen Geraetepfad)
if ($Exclude.Count -gt 0) {
    $files = @($files | Where-Object {
        $p = $_.path
        -not ($Exclude | Where-Object { $p -like $_ })
    })
    Write-Host "$($files.Count) Datei(en) nach Exclude-Filter."
}

if ($files.Count -eq 0) { Write-Host "Nichts herunterzuladen."; exit 0 }

# ── 2) Jede Datei chunked herunterladen ─────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$ok = 0; $failed = 0

foreach ($f in $files) {
    $remotePath = $f.path
    $relPath = $remotePath.TrimStart('/')
    $localPath = Join-Path $Destination $relPath
    $localDir = Split-Path -Parent $localPath
    if ($localDir) { New-Item -ItemType Directory -Force -Path $localDir | Out-Null }

    Write-Host ("Lade {0} ({1} Bytes)..." -f $remotePath, $f.size)
    $bytes = [System.Collections.Generic.List[byte]]::new()
    $offset = 0
    $eof = $false
    try {
        do {
            $resp = Invoke-Rpc @{
                method = "downloadFile"
                params = @{ filename = $remotePath; offset = $offset; chunk_size = $ChunkSize }
                timeout = 15000
            }
            if (-not $resp.success) { throw "downloadFile: $($resp.error)" }
            if ($resp.content) {
                $chunk = [Convert]::FromBase64String($resp.content)
                if ($chunk.Length -gt 0) { $bytes.AddRange($chunk) }
            }
            $offset = [int]$resp.next_offset
            $eof = [bool]$resp.eof
            $total = [int]$resp.size
        } while (-not $eof -and $offset -lt $total)

        [System.IO.File]::WriteAllBytes($localPath, $bytes.ToArray())
        Write-Host ("  -> {0} ({1} Bytes)" -f $localPath, $bytes.Count) -ForegroundColor Green
        $ok++
    } catch {
        Write-Warning ("  Fehler bei {0}: {1}" -f $remotePath, $_)
        $failed++
    }
}

Write-Host ""
Write-Host ("Fertig. {0} geladen, {1} fehlgeschlagen. Ziel: {2}" -f $ok, $failed, (Resolve-Path $Destination))
