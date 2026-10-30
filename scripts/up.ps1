$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
if (-not (Test-Path ".env")) { throw ".env is missing. Run .\scripts\setup.ps1 first." }
$tsLine = Get-Content ".env" | Where-Object { $_ -match "^\s*TS_AUTHKEY=" } | Select-Object -First 1
if (-not $tsLine -or $tsLine -match "REPLACE") { throw "Set a valid TS_AUTHKEY in .env." }
foreach ($name in @("SPARK_S3A_ACCESS_KEY", "SPARK_S3A_SECRET_KEY")) {
    $line = Get-Content ".env" | Where-Object { $_ -match "^\s*$name=" } | Select-Object -First 1
    if (-not $line -or $line -match "replace-") {
        throw "Configure $name with the dedicated MinIO Spark service-account credential in .env."
    }
}
docker compose config --quiet
docker compose up -d --build
Write-Host "Complete platform started. Inspect with: docker compose exec tailscale tailscale status"
