# cloneTestclient.ps1
# Legt einen neuen CPython-Testclient als Kopie von testclient/ an.
# Erstellt testclientN+1/ mit main.py und setzt das angegebene MQTT-Token in .env.
#
# Zweck:    Schnell einen weiteren Testclient fuer ein zweites ThingsBoard-Geraet
#           aufsetzen, ohne Dateien manuell zu kopieren.
#
# Aufruf:   .\cloneTestclient.ps1 -AccessToken "NeuesMqttToken"

param(
    [Parameter(Mandatory = $true)]
    [string]$AccessToken
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

$envContent = Get-Content ".\testclient\.env"

$highestClientNr = (Get-ChildItem -Path ".\" -Filter "testclient*" -Directory | Sort-Object -Descending)[0].Name.Substring(10)
Write-Host -ForegroundColor Green "$highestClientNr"

$targetDir = New-Item -ItemType Directory -Path ".\testclient$([int]$highestClientNr + 1)"
Write-Host "Erstelle Testclient im Verzeichnis: $($targetDir.FullName)"

Get-ChildItem -Path ".\testclient\" -Filter "*.py" -File | Copy-Item -Destination $targetDir.FullName
Write-Host "Kopiere Skripte und Dateien..."

Set-EnvValue "MQTT_ACCESS_TOKEN" $AccessToken

$envContent | Set-Content (Join-Path $targetDir.FullName ".env")
