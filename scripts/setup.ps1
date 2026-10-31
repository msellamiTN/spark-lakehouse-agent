$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI not found. Install Docker Desktop / Docker Engine."
}
docker compose version | Out-Null
if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "Created .env. Set JUPYTER_TOKEN, MINIO_ROOT_PASSWORD and TS_AUTHKEY."
    Read-Host "Press Enter after editing .env"
}
$envFile = Get-Content ".env" | Where-Object { $_ -match "^\s*[^#][^=]*=" }
$settings = @{}
foreach ($line in $envFile) {
    $parts = $line -split "=", 2
    $settings[$parts[0].Trim()] = $parts[1].Trim()
}
if (-not $settings["TS_AUTHKEY"] -or $settings["TS_AUTHKEY"] -like "*REPLACE*") {
    throw "Set TS_AUTHKEY to a reusable auth key tagged tag:spark-lakehouse-mcp."
}
if (-not $settings["JUPYTER_TOKEN"] -or $settings["JUPYTER_TOKEN"] -like "replace-*") {
    throw "Replace the sample JUPYTER_TOKEN in .env."
}
if (-not $settings["MINIO_ROOT_PASSWORD"] -or $settings["MINIO_ROOT_PASSWORD"] -like "replace-*") {
    throw "Replace the sample MINIO_ROOT_PASSWORD in .env."
}
@("notebooks", "retail", "lakehouse/raw", "lakehouse/bronze", "lakehouse/silver", "lakehouse/gold", "lakehouse/checkpoints", "secrets") |
    ForEach-Object { New-Item -ItemType Directory -Force $_ | Out-Null }
foreach ($secretFile in @("secrets/spark-s3a.env", "secrets/minio-mcp.env")) {
    if (-not (Test-Path $secretFile)) { New-Item -ItemType File $secretFile | Out-Null }
}
docker compose config --quiet
Write-Host "Setup checks passed. Run .\scripts\up.ps1 to start the complete stack."
