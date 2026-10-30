$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI not found. Install Docker Desktop."
}
docker compose version | Out-Null
if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "Created .env. Edit it and replace JUPYTER_TOKEN and MINIO_ROOT_PASSWORD."
    Read-Host "Press Enter after editing .env"
}
@("notebooks", "retail", "lakehouse/raw", "lakehouse/bronze", "lakehouse/silver", "lakehouse/gold", "lakehouse/checkpoints") |
    ForEach-Object { New-Item -ItemType Directory -Force $_ | Out-Null }
docker compose config --quiet
Write-Host "Setup checks passed. Start with .\scripts\up.ps1"
