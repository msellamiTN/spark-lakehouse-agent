$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

if (-not (Test-Path ".env")) { throw ".env is missing." }
$settings = @{}
Get-Content ".env" | ForEach-Object {
    if ($_ -match "^\s*([^#][^=]*)=(.*)$") { $settings[$matches[1].Trim()] = $matches[2].Trim() }
}
$rootUser = $settings["MINIO_ROOT_USER"]
$rootPassword = $settings["MINIO_ROOT_PASSWORD"]
if (-not $rootUser -or -not $rootPassword) { throw "Set MinIO root credentials in .env." }
if ($settings["MINIO_MCP_ALLOWED_BUCKETS"] -and $settings["MINIO_MCP_ALLOWED_BUCKETS"] -ne "lakehouse") {
    throw "This bootstrap provisions only the lakehouse bucket."
}
$policy = "minio-mcp-readonly.json"
if ($settings["MINIO_MCP_ALLOW_WRITES"] -eq "true") {
    if ($settings["MINIO_MCP_WRITE_PREFIXES"] -and $settings["MINIO_MCP_WRITE_PREFIXES"] -ne "agent-outputs/") {
        throw "IAM write permission is fixed to agent-outputs/."
    }
    $policy = "minio-mcp-write.json"
}

New-Item -ItemType Directory -Force "secrets" | Out-Null
$mcConfigName = ".mc-config-" + [guid]::NewGuid().ToString("N")
$mcConfigPath = Join-Path (Join-Path (Get-Location) "secrets") $mcConfigName
New-Item -ItemType Directory -Force $mcConfigPath | Out-Null
$mcConfigContainerPath = "/secrets/$mcConfigName"

function Invoke-Mc {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$McArgs)
    $output = & docker compose run --rm -T --no-deps minio-init --config-dir $mcConfigContainerPath @McArgs
    if ($LASTEXITCODE -ne 0) { throw "MinIO Client command failed (output suppressed for safety)." }
    return $output
}

function Ensure-MinIOAccessKey {
    param(
        [string]$File,
        [string]$AccessKey,
        [string]$PolicyFile,
        [string]$Label,
        [string]$AccessVariable,
        [string]$SecretVariable
    )
    if (Test-Path $File -PathType Leaf) {
        $lines = Get-Content $File
        $existing = ($lines | Where-Object { $_ -like "$AccessVariable=*" } | Select-Object -First 1) -replace "^$AccessVariable=", ""
        if ($existing -ne $AccessKey) { throw "$Label credential file contains an unexpected access key." }
        $null = Invoke-Mc admin user svcacct info local $AccessKey
        $null = Invoke-Mc admin user svcacct edit --policy "/policies/$PolicyFile" local $AccessKey
        Write-Host "PASS: existing $Label identity retained; policy reconciled."
        return
    }

    try {
        $null = Invoke-Mc admin user svcacct info local $AccessKey
        throw "$Label identity exists but its local secret file is missing. Refusing automatic rotation."
    } catch {
        if ($_.Exception.Message -like "$Label identity exists*") { throw }
    }

    $output = Invoke-Mc --json admin user svcacct add --access-key $AccessKey --policy "/policies/$PolicyFile" local $rootUser
    $result = ($output -join "`n") | ConvertFrom-Json
    if ($result.status -ne "success" -or -not $result.secretKey) { throw "MinIO did not return the expected $Label credentials." }
    $text = "$AccessVariable=$($result.accessKey)`n$SecretVariable=$($result.secretKey)`n"
    Set-Content -Path $File -Value $text -Encoding ascii -NoNewline
    Write-Host "PASS: created $Label identity; credentials saved locally."
}

try {
    Write-Host "Waiting for MinIO and configuring the temporary admin alias..."
    $null = Invoke-Mc alias set local http://minio:9000 $rootUser $rootPassword --api S3v4
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try { $null = Invoke-Mc ready local; $ready = $true; break } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $ready) { throw "MinIO did not become ready within 60 seconds." }

    $null = Invoke-Mc mb --ignore-existing local/lakehouse
    Write-Host "PASS: lakehouse bucket exists."
    Ensure-MinIOAccessKey "secrets/spark-s3a.env" "SPARKLAKEHOUSE01" "spark-lakehouse.json" "Spark" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY"
    Ensure-MinIOAccessKey "secrets/minio-mcp.env" "MINIOMCPLAKEHOUSE1" $policy "MinIO MCP" "MINIO_MCP_ACCESS_KEY" "MINIO_MCP_SECRET_KEY"
} finally {
    Remove-Item -Recurse -Force $mcConfigPath -ErrorAction SilentlyContinue
}
