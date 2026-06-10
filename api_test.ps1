$body = @{
    Messzeit     = "2026-06-10 14:30:00"
    Luftfeuchte  = 45.2
    Temperatur   = 22.5
    Druck        = 1013.25
    StandortID   = "Test"
} | ConvertTo-Json

try {
    $response = Invoke-WebRequest `
        -Uri "https://database3.protronic-gmbh.de/" `
        -Method POST `
        -ContentType "application/json" `
        -Body $body
    "Status: $($response.StatusCode)"
    $response.Content
} catch {
    "Status: $($_.Exception.Response.StatusCode.value__)"
    $_.ErrorDetails.Message
}