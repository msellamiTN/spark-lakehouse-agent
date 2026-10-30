$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
docker compose config --quiet
$services = @("spark-master", "spark-worker-1", "spark-worker-2", "jupyter", "ollama", "minio", "spark-mcp", "minio-mcp", "mcp-gateway", "tailscale")
foreach ($service in $services) {
    $id = docker compose ps -q $service
    if (-not $id) { throw "$service is not running" }
    if ($service -eq "minio") {
        Write-Host "PASS: minio is running"
        continue
    }
    if ($service -eq "tailscale") {
        Write-Host "PASS: tailscale container is running"
        continue
    }
    $health = docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' $id
    if ($health -ne "healthy") { throw "$service health is $health" }
    Write-Host "PASS: $service is healthy"
}
docker compose exec -T mcp-gateway wget -q -O /dev/null http://127.0.0.1:8080/healthz
if ($LASTEXITCODE -ne 0) { throw "MCP gateway health check failed" }
docker compose exec -T spark-mcp python3 -m unittest discover -s /app/tests -v
if ($LASTEXITCODE -ne 0) { throw "MCP guardrail tests failed" }
docker compose exec -T tailscale tailscale status
if ($LASTEXITCODE -ne 0) { throw "Tailscale node is not authenticated/connected" }
docker compose exec -T tailscale tailscale serve status
if ($LASTEXITCODE -ne 0) { throw "Tailscale Serve configuration unavailable" }
Write-Host "PASS: Tailscale node and Serve configuration"
Write-Host "Run the Linux validation script or the Jupyter Spark smoke test for full distributed integration validation."
