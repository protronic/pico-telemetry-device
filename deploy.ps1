param(
    [Parameter(Mandatory = $true)]
    [string]$AccessToken,
    [Parameter(Mandatory = $true)]
    [string]$Location
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
Set-EnvValue "MQTT_ACCESS_TOKEN" $AccessToken
Set-EnvValue "DEPLOY_LOCATION"   $Location
Set-EnvValue "DEPLOY_COMMIT_HASH" $CommitHash
Set-EnvValue "DEPLOY_GIT_URL"    $GitUrl

$envContent | Set-Content $EnvFile
# Write-Host "Token gesetzt: $AccessToken"
# Write-Host "Location gesetzt: $Location"
# Write-Host "Commit: $CommitHash"
# Write-Host "Git URL: $GitUrl"

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

Write-Host "Fertig."
