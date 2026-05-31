# deploy.ps1
# Uebertraegt src/ auf den Pico 2W – entweder per mpremote (USB) oder per
# ThingsBoard uploadFile-RPC (MQTT/HTTP, kein USB noetig).
#
# Zweck:    Bei jedem Deployment auf den Pico ausfuehren.
#
# Aufruf:   .\deploy.ps1 -AccessToken "MqttToken" -Location "Standort"
#           .\deploy.ps1 -t "MqttToken" -l "Standort"
#           .\deploy.ps1 -t "MqttToken" -l "Standort" -Method RPC -DeviceId "uuid"
#           .\.deploy.ps1 -n 1 -m RPC          (lookup via DEVICE_ID_1, DEVICE_AT_1, DEVICE_LOCATION_1)
#           .\deploy.ps1 -n DEV -m RPC        (lookup via DEVICE_ID_DEV, DEVICE_AT_DEV, DEVICE_LOCATION_DEV)
#           .\deploy.ps1 -n DEV -m RPC -UseTestClient  (deploy testclient/ instead of src/)
#           .\deploy.ps1 -m scp -Target "pi@raspberrypi:/home/pi/app/"  (SCP deploy)

param(
    [Alias("l")]
    [string]$Location = "Testdevice",
    [Alias("t")]
    [string]$AccessToken = "",
    [Alias("m")]
    [ValidateSet("mpremote", "RPC", "scp")]
    [string]$Method = "mpremote",
    [Alias("d")]
    [string]$DeviceId = "",
    [Alias("n")]
    [string]$DeviceNr = "",
    [Alias("T")]
    [string]$Target = "",
    [switch]$UseTestClient
)

function Get-EnvValue {
    param([string]$Key)
    $line = $script:envContent | Where-Object { $_ -match "^$Key=" }
    if ($line) {
        return ($line -split "=", 2)[1]
    }
    return $null
}

function Set-EnvValue {
    param([string]$Key, [string]$Value)
    if ($script:envContent -match "^$Key=") {
        $script:envContent = $script:envContent -replace "^$Key=.*", "$Key=$Value"
    } else {
        $script:envContent += "$Key=$Value"
    }
}

$SrcDir = if ($UseTestClient) { Join-Path $PSScriptRoot "testclient" } else { Join-Path $PSScriptRoot "src" }
if ($UseTestClient) { Write-Host "Quelle: testclient/" }
$EnvFile = Join-Path $SrcDir ".env"
$envContent = Get-Content $EnvFile

# Root .env laden
$deployEnvRaw = @{}
Get-Content (Join-Path $PSScriptRoot ".env") | Where-Object { $_ -match "^[^#]+=.+" } |
    ForEach-Object { $k, $v = $_ -split "=", 2; $deployEnvRaw[$k.Trim()] = $v.Trim() }

# DeviceNr: ID, AccessToken und Location aus root .env nachschlagen
if ($DeviceNr) {
    $nr = $DeviceNr.ToUpper()
    if ($deployEnvRaw["DEVICE_ID_$nr"])       { $DeviceId     = $deployEnvRaw["DEVICE_ID_$nr"] }
    if ($deployEnvRaw["DEVICE_AT_$nr"])       { $AccessToken  = $deployEnvRaw["DEVICE_AT_$nr"] }
    if ($deployEnvRaw["DEVICE_LOCATION_$nr"]) { $Location     = $deployEnvRaw["DEVICE_LOCATION_$nr"] }
    if (-not $DeviceId) {
        Write-Error "DEVICE_ID_$nr nicht in .env gefunden."
        exit 1
    }
    Write-Host "DeviceNr $nr -> $Location ($DeviceId)"
}

$DeployStatus = (-not $AccessToken) ? "development" : "production"

# Git commit vor dem Deploy
Write-Host "Committe Aenderungen..."
git -C $PSScriptRoot add -A
git -C $PSScriptRoot commit -m "force commit; deploy $Location" 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "Hinweis: Nichts zu commiten oder commit fehlgeschlagen."
}

# Git Infos auslesen
$CommitHash = git -C $PSScriptRoot rev-parse HEAD
$GitUrl = git -C $PSScriptRoot remote get-url origin

# .env mit neuem Token, Location und Git-Infos aktualisieren
if (-not $AccessToken) {
    $AccessToken = $deployEnvRaw["DEVICE_AT_DEV"]
}
if ($DeviceId) {
    Set-EnvValue "DEPLOY_DEVICE_ID" $DeviceId
}
Set-EnvValue "MQTT_ACCESS_TOKEN" $AccessToken
Set-EnvValue "DEPLOY_LOCATION"   $Location
Set-EnvValue "DEPLOY_COMMIT_HASH" $CommitHash
Set-EnvValue "DEPLOY_GIT_URL"    $GitUrl
Set-EnvValue "DEPLOY_STATUS"     $DeployStatus

$envContent | Set-Content $EnvFile

# ── Deploy-Funktionen ─────────────────────────────────────────────────────────

function Deploy-ViaScp {
    if (-not $Target) {
        Write-Error "Bitte -Target 'user@host:/remote/path/' angeben."
        return
    }
    $remoteBase = $Target.TrimEnd('/') + '/'
    # Host-Teil fuer ssh (alles vor dem ersten ':')
    $sshHost = ($remoteBase -split ':')[0]

    $files = Get-ChildItem $SrcDir -File | Where-Object { $_.Extension -eq ".py" -or $_.Name -eq ".env" }
    foreach ($file in $files) {
        Write-Host "SCP: $($file.Name)"
        scp "$($file.FullName)" "${remoteBase}$($file.Name)"
        if ($LASTEXITCODE -ne 0) { Write-Error "SCP fehlgeschlagen fuer $($file.Name)"; return }
    }

    $LibDir = Join-Path $SrcDir "Lib"
    if (Test-Path $LibDir) {
        $libFiles = Get-ChildItem $LibDir -Recurse -File
        foreach ($file in $libFiles) {
            $relativePath = $file.FullName.Substring($SrcDir.Length + 1).Replace("\\", "/")
            $relDir = ($relativePath | Split-Path -Parent).Replace("\\", "/")
            $remoteDir = ($remoteBase -replace '^[^:]+:', '') + $relDir
            Write-Host "SCP: $relativePath"
            ssh $sshHost "mkdir -p '$remoteDir'" 2>$null
            scp "$($file.FullName)" "${remoteBase}${relativePath}"
            if ($LASTEXITCODE -ne 0) { Write-Error "SCP fehlgeschlagen fuer $relativePath"; return }
        }
    }
}

function Deploy-ViaMpremote {
    # .py Dateien und .env auf Geraet uebertragen
    $files = Get-ChildItem $SrcDir -File | Where-Object { $_.Extension -eq ".py" -or $_.Name -eq ".env" }
    foreach ($file in $files) {
        Write-Host "Kopiere: $($file.Name)"
        python -m mpremote cp "$($file.FullName)" ":$($file.Name)"
    }

    # Lib Ordner rekursiv uebertragen (Struktur beibehalten)
    $LibDir = Join-Path $SrcDir "Lib"
    if (Test-Path $LibDir) {
        $libFiles = Get-ChildItem $LibDir -Recurse -File
        foreach ($file in $libFiles) {
            $relativePath = $file.FullName.Substring($SrcDir.Length + 1).Replace("\", "/")
            $remoteDir = ":" + ($relativePath | Split-Path -Parent).Replace("\", "/")
            Write-Host "Kopiere: $relativePath"
            python -m mpremote mkdir $remoteDir 2>$null
            python -m mpremote cp "$($file.FullName)" ":$relativePath"
        }
    }
}

function Resolve-DeviceId {
    param([string]$Location, [hashtable]$Headers, [string]$BaseUrl, [string]$DeviceInfoUrl, [string]$DeviceAttrPath)

    # Alle PicoData-Geraete abrufen
    $resp = Invoke-RestMethod -Uri $DeviceInfoUrl `
        -Headers $Headers -ErrorAction Stop
    $devices = $resp.data | Where-Object { $_.deviceProfileName -eq "PicoData" }

    foreach ($device in $devices) {
        $attrUrl = $BaseUrl + ($DeviceAttrPath -replace '%s', $device.id.id)
        $attrs = Invoke-RestMethod -Uri $attrUrl `
            -Headers $Headers -ErrorAction SilentlyContinue
        $locationAttr = $attrs | Where-Object { $_.key -eq "location" }
        if ($locationAttr -and $locationAttr.value -eq $Location) {
            Write-Host "Geraet gefunden: $($device.name) ($($device.id.id))"
            return $device.id.id
        }
    }
    return $null
}

function Deploy-ViaRpc {
    param([string]$DeviceId)

    # Credentials aus root .env laden
    $deployEnvFile = Join-Path $PSScriptRoot ".env"
    if (-not (Test-Path $deployEnvFile)) {
        Write-Error ".env nicht gefunden: $deployEnvFile"
        return
    }
    $deployEnv = Get-Content $deployEnvFile | Where-Object { $_ -match "^[^#]+=.+" } |
        ForEach-Object { $k, $v = $_ -split "=", 2; @{ Key = $k.Trim(); Value = $v.Trim() } }
    $envMap = @{}
    $deployEnv | ForEach-Object { $envMap[$_.Key] = $_.Value }

    $baseUrl      = $envMap["THINGSBOARD_BASE_URL"]
    $loginUrl     = $baseUrl + $envMap["THINGSBOARD_LOGIN_PATH"]
    $rpcPath      = $envMap["THINGSBOARD_RPC_PATH"]
    $userUrl      = $baseUrl + $envMap["THINGSBOARD_USER_PATH"]
    $verifyPath   = $envMap["THINGSBOARD_VERIFY_PATH"]
    $deviceInfoUrl     = $baseUrl + $envMap["THINGSBOARD_DEVICE_INFO_PATH"]
    $deviceAttrPath    = $envMap["THINGSBOARD_DEVICE_ATTRIBUTE_PATH"]
    $tbUser       = $envMap["THINGSBOARD_USERNAME"]

    if (-not $baseUrl) {
        Write-Error "THINGSBOARD_BASE_URL fehlt in .env"
        return
    }
    if (-not $rpcPath) {
        Write-Error "THINGSBOARD_RPC_PATH fehlt in .env"
        return
    }
    if (-not $envMap["THINGSBOARD_LOGIN_PATH"]) {
        Write-Error "THINGSBOARD_LOGIN_PATH fehlt in .env"
        return
    }

    # JWT aus Cache laden (gespeichert in %TEMP%\tb_jwt_<user>.json)
    function Get-JwtExpiry([string]$token) {
        try {
            $payload = $token.Split('.')[1]
            # Base64url → Base64
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
            # Kurz pruefen ob Token noch akzeptiert wird
            try {
                Invoke-RestMethod -Uri $userUrl -Headers $headers -ErrorAction Stop | Out-Null
            } catch {
                Write-Warning "Gecachtes Token abgelaufen – neu anmelden."
                $headers = $null
            }
        } else {
            Write-Host "Gecachtes JWT-Token abgelaufen – neu anmelden."
        }
    }

    if (-not $headers) {
        $tbPass = Read-Host "Passwort fuer $tbUser" -AsSecureString
        if (-not $tbPass -or $tbPass.Length -eq 0) {
            Write-Error "Kein Passwort eingegeben. Abbruch."
            return
        }
        $tbPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tbPass))

        try {
            $login = Invoke-RestMethod -Uri $loginUrl `
                -Method POST -ContentType "application/json" `
                -Body "{`"username`":`"$tbUser`",`"password`":`"$tbPassPlain`"}" `
                -ErrorAction Stop
        } catch {
            Write-Error "Login fehlgeschlagen: $_"
            return
        }

        # 2FA: ThingsBoard gibt token mit scope=PRE_VERIFICATION_TOKEN zurueck
        if ($login.scope -eq "PRE_VERIFICATION_TOKEN") {
            $totpCode = Read-Host "2FA-Code (TOTP)"
            try {
                $verifyUrl = $baseUrl + ($verifyPath -replace '%s', $totpCode)
                $mfaCheck = Invoke-RestMethod -Uri $verifyUrl `
                    -Method POST `
                    -Headers @{ Authorization = "Bearer $($login.token)" } `
                    -ErrorAction Stop
            } catch {
                Write-Error "2FA-Verifikation fehlgeschlagen: $_"
                return
            }
            $jwt = $mfaCheck.token
        } elseif ($login.token) {
            $jwt = $login.token
        } else {
            Write-Error "Login-Response enthaelt kein token. Abbruch."
            return
        }

        $headers = @{ Authorization = "Bearer $jwt" }
        @{ token = $jwt } | ConvertTo-Json | Set-Content $cacheFile
        Write-Host "Login erfolgreich. Token gecacht in $cacheFile"
    }

    # DeviceId per Location-Attribut nachschlagen, falls nicht angegeben
    if (-not $DeviceId) {
        Write-Host "Suche Geraet mit location='$Location'..."
        $DeviceId = Resolve-DeviceId -Location $Location -Headers $headers -BaseUrl $baseUrl -DeviceInfoUrl $deviceInfoUrl -DeviceAttrPath $deviceAttrPath
        if (-not $DeviceId) {
            Write-Error "Kein PicoData-Geraet mit location='$Location' gefunden. Bitte -DeviceId angeben."
            return
        }
    }

    # .py Dateien und .env per uploadFile RPC uebertragen
    $rpcUrl = $baseUrl + ($rpcPath -replace '%s', $DeviceId)
    $files = Get-ChildItem $SrcDir -File | Where-Object { $_.Extension -eq ".py" -or $_.Name -eq ".env" }
    foreach ($file in $files) {
        Write-Host "RPC uploadFile: $($file.Name)"
        $content = Get-Content $file.FullName -Raw
        $body = @{ method = "uploadFile"; params = @{ filename = $file.Name; content = $content }; timeout = 15000 } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri $rpcUrl `
            -Method POST -ContentType "application/json" `
            -Headers $headers -Body $body -ErrorAction Stop | Out-Null
    }

    # Lib Ordner rekursiv uebertragen
    $LibDir = Join-Path $SrcDir "Lib"
    if (Test-Path $LibDir) {
        $libFiles = Get-ChildItem $LibDir -Recurse -File
        foreach ($file in $libFiles) {
            $relativePath = $file.FullName.Substring($SrcDir.Length + 1).Replace("\", "/")
            Write-Host "RPC uploadFile: $relativePath"
            $content = Get-Content $file.FullName -Raw
            $body = @{ method = "uploadFile"; params = @{ filename = $relativePath; content = $content }; timeout = 15000 } | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri $rpcUrl `
                -Method POST -ContentType "application/json" `
                -Headers $headers -Body $body -ErrorAction Stop | Out-Null
        }
    }
}

# ── Deployment ausführen ──────────────────────────────────────────────────────

if ($Method -eq "RPC") {
    Write-Host "Deployment per ThingsBoard RPC..."
    Deploy-ViaRpc -DeviceId $DeviceId
} elseif ($Method -eq "scp") {
    Write-Host "Deployment per SCP nach $Target..."
    Deploy-ViaScp
} else {
    Write-Host "Deployment per mpremote (USB)..."
    Deploy-ViaMpremote
}

Write-Host "Fertig."
