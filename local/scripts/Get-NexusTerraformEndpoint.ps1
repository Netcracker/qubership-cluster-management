#requires -Version 7.0
# Terraform external data source: stdin and stdout contain JSON objects.
# Discover only Floci's published port; the HTTP provider checks Nexus readiness.
param(
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
    [ValidateRange(1, 60)][int]$PollIntervalSeconds = 5
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

try {
    $query = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $instanceId = [string]$query.instance_id
    if ($instanceId -notmatch '^i-[a-f0-9]+$') {
        throw 'Expected a valid instance_id in the Terraform JSON query.'
    }

    $null = Get-Command docker -ErrorAction Stop
    $dockerInfo = & docker info --format '{{.ServerVersion}}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker is unavailable. Start Docker Desktop before running the local workflow.'
    }

    $publisher = "floci-aws-ec2-fwd-$instanceId-8081"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $bindings = & docker port $publisher 8081/tcp 2>&1
        if ($LASTEXITCODE -eq 0) {
            foreach ($binding in $bindings) {
                if ([string]$binding -match '^(?:0\.0\.0\.0|127\.0\.0\.1):(\d+)\s*$') {
                    $port = [int]$Matches[1]
                    if ($port -ge 1 -and $port -le 65535) {
                        @{ url = "http://127.0.0.1:$port/service/rest/v1/status/writable" } |
                            ConvertTo-Json -Compress
                        exit 0
                    }
                }
            }
        }
        $remainingMs = ($TimeoutSeconds * 1000) - $timer.ElapsedMilliseconds
        if ($remainingMs -le 0) {
            throw "No IPv4 HTTP port published by $publisher within $TimeoutSeconds seconds."
        }
        Start-Sleep -Milliseconds ([int][Math]::Min($PollIntervalSeconds * 1000, $remainingMs))
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
