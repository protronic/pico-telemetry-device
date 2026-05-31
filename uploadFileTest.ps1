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
$tbUser = Read-Host "ThingsBoard Benutzer"
$tbPass = Read-Host "Passwort" -AsSecureString
$tbPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tbPass))
$login = Invoke-RestMethod -Uri "http://thingsboard:8080/api/auth/login" `
    -Method POST -ContentType "application/json" `
    -Body "{`"username`":`"$tbUser`",`"password`":`"$tbPassPlain`"}"
$jwt = $login.token

# Device-ID des Testclient-Geräts (aus ThingsBoard UI kopieren)
$deviceId = "ec870240-5c86-11f1-92d9-93754c56e8e7"

# uploadFile RPC senden
Invoke-RestMethod -Uri "http://thingsboard:8080/api/rpc/twoway/$deviceId" `
    -Method POST -ContentType "application/json" `
    -Headers @{Authorization="Bearer $jwt"} `
    -Body '{"method":"uploadFile","params":{"filename":"test.py","content":"print(\"hello\")"},"timeout":10000}' `
    -ErrorAction Stop