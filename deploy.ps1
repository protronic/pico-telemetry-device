# deploy.ps1
# Uebertraegt src/ auf den Pico 2W – entweder per mpremote (USB) oder per
# ThingsBoard uploadFile-RPC (MQTT/HTTP, kein USB noetig).
#
# Zweck:    Bei jedem Deployment auf den Pico ausfuehren.
#
# Aufruf:   .\deploy.ps1 -AccessToken "MqttToken" -Location "Standort"
#           .\deploy.ps1 -t "MqttToken" -l "Standort"
#           .\deploy.ps1 -t "MqttToken" -l "Standort" -Method RPC -DeviceId "uuid"

param(
    [Alias("l")]
    [string]$Location = "Testdevice",
    [Alias("t")]
    [string]$AccessToken = "",
    [Alias("m")]
    [ValidateSet("mpremote", "RPC")]
    [string]$Method = "mpremote",
    [Alias("d")]
    [string]$DeviceId = ""
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

$SrcDir = Join-Path $PSScriptRoot "src"
$EnvFile = Join-Path $SrcDir ".env"
$envContent = Get-Content $EnvFile
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
    $AccessToken = Get-EnvValue "MQTT_ACCESS_TOKEN_DEV"
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
    param([string]$Location, [hashtable]$Headers, [string]$BaseUrl)

    # Alle PicoData-Geraete abrufen
    $resp = Invoke-RestMethod -Uri "$BaseUrl/api/tenant/deviceInfos?pageSize=100&page=0&sortProperty=name&sortOrder=ASC" `
        -Headers $Headers -ErrorAction Stop
    $devices = $resp.data | Where-Object { $_.deviceProfileName -eq "PicoData" }

    foreach ($device in $devices) {
        $attrs = Invoke-RestMethod -Uri "$BaseUrl/api/plugins/telemetry/DEVICE/$($device.id.id)/values/attributes/CLIENT_SCOPE" `
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

    $apiKey   = $envMap["THINGSBOARD_API_KEY"]
    $rpcUrl   = $envMap["THINGSBOARD_RPC_URL"]
    $loginUrl = $envMap["THINGSBOARD_LOGIN_URL"]

    if (-not $rpcUrl) {
        Write-Error "THINGSBOARD_RPC_URL fehlt in .env"
        return
    }

    $baseUrl = $rpcUrl -replace "/api/rpc/twoway/?$", ""

    # API-Key versuchen, bei Fehler (401/403) auf Login-Flow fallback
    $headers = $null
    if ($apiKey) {
        Write-Host "Pruefe API-Key..."
        $testHeaders = @{ Authorization = "Bearer $apiKey" }
        try {
            # /api/auth/user gibt 200 bei gueltigem Token, 401 bei ungueltigem
            Invoke-RestMethod -Uri "$baseUrl/api/auth/user" `
                -Headers $testHeaders -ErrorAction Stop | Out-Null
            $headers = $testHeaders
            Write-Host "API-Key gueltig."
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            Write-Warning "API-Key ungueltig oder abgelaufen (HTTP $statusCode) – falle zurueck auf Login."
        }
    }

    if (-not $headers) {
        # Login-Flow als Fallback
        if (-not $loginUrl) {
            Write-Error "Kein API-Key und THINGSBOARD_LOGIN_URL fehlt in .env"
            return
        }
        $tbUser = $envMap["THINGSBOARD_USERNAME"]
        if (-not $tbUser) { $tbUser = Read-Host "ThingsBoard Benutzer" }
        $tbPass = Read-Host "Passwort fuer $tbUser" -AsSecureString
        $tbPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tbPass))
        $login = Invoke-RestMethod -Uri $loginUrl `
            -Method POST -ContentType "application/json" `
            -Body "{`"username`":`"$tbUser`",`"password`":`"$tbPassPlain`"}" `
            -ErrorAction Stop
        $headers = @{ Authorization = "Bearer $($login.token)" }
        Write-Host "Login erfolgreich."
    }

    # DeviceId per Location-Attribut nachschlagen, falls nicht angegeben
    if (-not $DeviceId) {
        Write-Host "Suche Geraet mit location='$Location'..."
        $DeviceId = Resolve-DeviceId -Location $Location -Headers $headers -BaseUrl $baseUrl
        if (-not $DeviceId) {
            Write-Error "Kein PicoData-Geraet mit location='$Location' gefunden. Bitte -DeviceId angeben."
            return
        }
    }

    # .py Dateien und .env per uploadFile RPC uebertragen
    $files = Get-ChildItem $SrcDir -File | Where-Object { $_.Extension -eq ".py" -or $_.Name -eq ".env" }
    foreach ($file in $files) {
        Write-Host "RPC uploadFile: $($file.Name)"
        $content = Get-Content $file.FullName -Raw
        $body = @{ method = "uploadFile"; params = @{ filename = $file.Name; content = $content }; timeout = 15000 } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri "$rpcUrl$DeviceId" `
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
            Invoke-RestMethod -Uri "$rpcUrl$DeviceId" `
                -Method POST -ContentType "application/json" `
                -Headers $headers -Body $body -ErrorAction Stop | Out-Null
        }
    }
}

# ── Deployment ausführen ──────────────────────────────────────────────────────

if ($Method -eq "RPC") {
    Write-Host "Deployment per ThingsBoard RPC..."
    Deploy-ViaRpc -DeviceId $DeviceId
} else {
    Write-Host "Deployment per mpremote (USB)..."
    Deploy-ViaMpremote
}

Write-Host "Fertig."
