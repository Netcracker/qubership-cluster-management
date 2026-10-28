#requires -Version 7.0
param([Parameter(Mandatory)][string]$Stack)
$ErrorActionPreference = 'Stop'
if ($Stack -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { throw "Invalid stack name: $Stack" }
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $projectRoot
try {
    # Do not resolve Terraform outputs while its after-apply hook is running.
    # Keep machine-readable data separate from CLI messages, including in parallel workflows.
    $configFile = Join-Path ([IO.Path]::GetTempPath()) ("atmos-nexus-" + [guid]::NewGuid() + '.json')
    try {
        $messages = & atmos describe component nexus -s $Stack --process-functions=false --format json --file $configFile 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Cannot describe Nexus for stack ${Stack}: $($messages -join "`n")" }
        if (-not (Test-Path -LiteralPath $configFile)) { throw "Atmos did not write Nexus configuration for stack $Stack." }
        $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
        if ($null -eq $config) { throw "Atmos wrote an empty Nexus configuration for stack $Stack." }
    } finally {
        if (Test-Path -LiteralPath $configFile) { Remove-Item -LiteralPath $configFile -Force }
    }
    $identity = [string]$config.vars.environment
    if (-not $identity) { throw "Stack $Stack has no environment identity." }

    $arguments = @('ec2', 'describe-instances', '--filters',
        "Name=tag:Name,Values=$identity-nexus", 'Name=tag:Role,Values=nexus',
        'Name=instance-state-name,Values=running', '--region', [string]$config.vars.region,
        '--output', 'json', '--no-cli-pager')
    $isLocal = -not [string]::IsNullOrEmpty([string]$config.vars.local_endpoint)
    if ($isLocal) {
        $arguments += @('--endpoint-url', [string]$config.vars.local_endpoint)
        $env:NO_PROXY = ((@($env:NO_PROXY -split ',') + @('localhost','127.0.0.1','::1','floci')) |
            Where-Object { $_ } | Select-Object -Unique) -join ','
        $env:AWS_ACCESS_KEY_ID = 'test'
        $env:AWS_SECRET_ACCESS_KEY = 'test'
        $env:AWS_PROFILE = $null
    } elseif ($config.env.AWS_PROFILE) {
        $arguments += @('--profile', [string]$config.env.AWS_PROFILE)
    }
    $env:AWS_PAGER = ''
    $env:AWS_EC2_METADATA_DISABLED = 'true'
    $raw = & aws @arguments
    if ($LASTEXITCODE -ne 0) { throw "Cannot find the Nexus instance for stack $Stack." }
    $instances = @((($raw -join "`n") | ConvertFrom-Json).Reservations.Instances |
        Where-Object { $_.InstanceId })
    if ($instances.Count -ne 1) {
        throw "Expected one running Nexus instance for $Stack; found $($instances.Count)."
    }
    $instance = $instances[0]
    if ($isLocal) {
        # Floci publishes container port 8081 on a dynamically assigned host port.
        $publisher = "floci-aws-ec2-fwd-$($instance.InstanceId)-8081"
        $bindings = & docker port $publisher 8081/tcp 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Nexus port publisher $publisher is not ready." }
        $port = $null
        foreach ($binding in $bindings) {
            if ([string]$binding -match ':(\d+)\s*$') { $port = [int]$Matches[1]; break }
        }
        if (-not $port) { throw "No published HTTP port was found for $publisher." }
        Write-Output "http://127.0.0.1:$port/service/rest/v1/status/writable"
    } else {
        $address = if ($instance.PublicIpAddress) { $instance.PublicIpAddress } else { $instance.PrivateIpAddress }
        if (-not $address) { throw "Nexus instance $($instance.InstanceId) has no usable IP address." }
        Write-Output "http://${address}:8081/service/rest/v1/status/writable"
    }
} finally { Pop-Location }
