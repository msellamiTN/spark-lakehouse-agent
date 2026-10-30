$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
docker compose config --quiet

$services = @("spark-master", "spark-worker-1", "spark-worker-2", "jupyter", "ollama", "minio", "spark-mcp", "minio-mcp", "mcp-gateway", "tailscale")
foreach ($service in $services) {
    $id = docker compose ps -q $service
    if (-not $id) { throw "$service is not running" }
    if ($service -eq "minio" -or $service -eq "tailscale") {
        Write-Host "PASS: $service container is running"
        continue
    }
    $health = docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' $id
    if ($health -ne "healthy") { throw "$service health is $health" }
    Write-Host "PASS: $service is healthy"
}

docker compose exec -T mcp-gateway wget -q -O /dev/null http://127.0.0.1:8080/healthz
if ($LASTEXITCODE -ne 0) { throw "MCP gateway health check failed" }
Write-Host "PASS: MCP gateway health"

docker compose exec -T spark-mcp python3 -m unittest discover -s /app/tests -v
if ($LASTEXITCODE -ne 0) { throw "MCP guardrail tests failed" }
Write-Host "PASS: MCP guardrail tests"

@'
from pyspark.sql import SparkSession
spark = (SparkSession.builder
    .appName("phase1-validation")
    .master("spark://spark-master:7077")
    .config("spark.executor.instances", "2")
    .getOrCreate())
count = spark.range(0, 1000).count()
assert count == 1000, count
print("Distributed count:", count, "Spark:", spark.version)
spark.stop()
'@ | docker compose exec -T jupyter python3 -
if ($LASTEXITCODE -ne 0) { throw "Jupyter-to-Spark integration failed" }
Write-Host "PASS: Jupyter-to-Spark integration"

docker compose exec -T jupyter python3 -c "import requests; r=requests.get('http://minio:9000/minio/health/live',timeout=5); r.raise_for_status(); print('MinIO:',r.status_code)"
if ($LASTEXITCODE -ne 0) { throw "MinIO health check failed" }
Write-Host "PASS: MinIO upstream"

docker compose exec -T tailscale tailscale status
if ($LASTEXITCODE -ne 0) { throw "Tailscale node is not authenticated/connected" }
docker compose exec -T tailscale tailscale serve status
if ($LASTEXITCODE -ne 0) { throw "Tailscale Serve configuration unavailable" }
Write-Host "PASS: Tailscale node and Serve configuration"
Write-Host "All Phase 1 infrastructure and Tailscale checks passed."
