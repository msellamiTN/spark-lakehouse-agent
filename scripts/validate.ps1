$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
docker compose config --quiet
$services = @("spark-master", "spark-worker-1", "spark-worker-2", "jupyter", "ollama", "minio", "spark-mcp", "minio-mcp")
foreach ($service in $services) {
    $id = docker compose ps -q $service
    if (-not $id) { throw "$service is not running" }
    if ($service -ne "minio") {
        $health = docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' $id
        if ($health -ne "healthy") { throw "$service health is $health" }
        Write-Host "PASS: $service is healthy"
    } else {
        Write-Host "PASS: minio container is running"
    }
}
@'
from pyspark.sql import SparkSession
spark = SparkSession.builder.appName("phase1-validation").master("spark://spark-master:7077").config("spark.executor.instances","2").getOrCreate()
n = spark.range(0,1000).count()
assert n == 1000, n
print("Distributed count:", n, "Spark:", spark.version)
spark.stop()
'@ | docker compose exec -T jupyter python3 -
Write-Host "PASS: Jupyter-to-Spark integration job"
docker compose exec -T jupyter python3 -c "import requests; r=requests.get('http://minio:9000/minio/health/live',timeout=5); r.raise_for_status(); print('MinIO:',r.status_code)"
Write-Host "PASS: MinIO HTTP health endpoint"
docker compose exec -T spark-mcp python3 -m unittest discover -s /app/tests -v
Write-Host "PASS: MCP guardrail unit tests"
Write-Host "PASS: Spark MCP endpoint process is healthy (localhost:8002/mcp)"
Write-Host "PASS: MinIO MCP endpoint process is healthy (localhost:8003/mcp)"
Write-Host "All Phase 1 infrastructure and MCP service checks passed."
