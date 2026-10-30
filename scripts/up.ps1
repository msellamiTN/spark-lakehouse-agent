$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
if (-not (Test-Path ".env")) { throw ".env is missing. Run .\scripts\setup.ps1 first." }
$tsLine = Get-Content ".env" | Where-Object { $_ -match "^\s*TS_AUTHKEY=" } | Select-Object -First 1
if (-not $tsLine -or $tsLine -match "REPLACE") { throw "Set a valid TS_AUTHKEY in .env." }
docker compose config --quiet
docker compose up -d --build
Write-Host "Complete platform started. Inspect with: docker compose exec tailscale tailscale status"
