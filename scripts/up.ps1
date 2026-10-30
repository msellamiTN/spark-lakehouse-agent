$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
if (-not (Test-Path ".env")) { throw ".env is missing. Run .\scripts\setup.ps1 first." }
$tsLine = Get-Content ".env" | Where-Object { $_ -match "^\s*TS_AUTHKEY=" } | Select-Object -First 1
if (-not $tsLine -or $tsLine -match "REPLACE") { throw "Set a valid TS_AUTHKEY in .env." }
$sparkImageLine = Get-Content ".env" | Where-Object { $_ -match "^\s*SPARK_IMAGE=" } | Select-Object -First 1
if (-not $sparkImageLine -or $sparkImageLine -notmatch "spark-lakehouse-s3a:3.5.6") {
    throw "Set SPARK_IMAGE=spark-lakehouse-s3a:3.5.6 in .env."
}
$hadoopLine = Get-Content ".env" | Where-Object { $_ -match "^\s*HADOOP_VERSION=" } | Select-Object -First 1
if ($hadoopLine -and $hadoopLine -notmatch "HADOOP_VERSION=3\.3\.4") {
    throw "HADOOP_VERSION must remain 3.3.4 for this Spark base image."
}
$awsSdkLine = Get-Content ".env" | Where-Object { $_ -match "^\s*AWS_SDK_BUNDLE_VERSION=" } | Select-Object -First 1
if ($awsSdkLine -and $awsSdkLine -notmatch "AWS_SDK_BUNDLE_VERSION=1\.12\.262") {
    throw "AWS_SDK_BUNDLE_VERSION must remain 1.12.262 for hadoop-aws 3.3.4."
}
}
docker compose config --quiet
if ($LASTEXITCODE -ne 0) { throw "Compose configuration is invalid" }
# Build the shared Spark/S3A base before Jupyter and MCP images that inherit it.
docker compose build spark-master
if ($LASTEXITCODE -ne 0) { throw "Spark S3A base image build failed" }
docker compose build jupyter spark-mcp minio-mcp
if ($LASTEXITCODE -ne 0) { throw "Jupyter/MCP image build failed" }
docker compose up -d
if ($LASTEXITCODE -ne 0) { throw "Compose startup failed" }
Write-Host "Complete platform started. Inspect with: docker compose exec tailscale tailscale status"
