$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
if (-not (Test-Path ".env")) { throw ".env is missing. Run .\scripts\setup.ps1 first." }
$tsLine = Get-Content ".env" | Where-Object { $_ -match "^\s*TS_AUTHKEY=" } | Select-Object -First 1
if (-not $tsLine -or $tsLine -match "REPLACE") { throw "Set a valid TS_AUTHKEY in .env." }
$sparkImageLine = Get-Content ".env" | Where-Object { $_ -match "^\s*SPARK_IMAGE=" } | Select-Object -First 1
if (-not $sparkImageLine -or $sparkImageLine -notmatch "spark-lakehouse-s3a:3.5.6") {
    throw "Set SPARK_IMAGE=spark-lakehouse-s3a:3.5.6 in .env."
}
foreach ($name in @("SPARK_S3A_ACCESS_KEY", "SPARK_S3A_SECRET_KEY")) {
    $line = Get-Content ".env" | Where-Object { $_ -match "^\s*$name=" } | Select-Object -First 1
    if (-not $line -or $line -match "replace-") {
        throw "Configure $name with the dedicated MinIO Spark service-account credential in .env."
    }
}
docker compose config --quiet
# Build the shared Spark/S3A base before Jupyter and MCP images that inherit it.
docker compose build spark-master
if ($LASTEXITCODE -ne 0) { throw "Spark S3A base image build failed" }
docker compose build jupyter spark-mcp minio-mcp
if ($LASTEXITCODE -ne 0) { throw "Jupyter/MCP image build failed" }
docker compose up -d
Write-Host "Complete platform started. Inspect with: docker compose exec tailscale tailscale status"
