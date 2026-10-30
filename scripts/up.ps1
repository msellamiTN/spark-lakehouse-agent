$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
if (-not (Test-Path ".env")) {
    throw ".env is missing. Run .\scripts\setup.ps1 first."
}
docker compose config --quiet
docker compose up -d --build
Write-Host "Services started. Run .\scripts\validate.ps1"
