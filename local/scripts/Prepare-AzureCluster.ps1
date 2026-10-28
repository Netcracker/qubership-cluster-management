#requires -Version 7.0
param([Parameter(Mandatory)][string]$Stack)
$ErrorActionPreference = 'Stop'
if ($Stack -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { throw 'Invalid stack name.' }
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $root
$configFile = Join-Path ([IO.Path]::GetTempPath()) ("atmos-azure-" + [guid]::NewGuid() + '.json')
try {
    $messages = & atmos describe component argocd -s $Stack --format json --file $configFile 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Cannot describe ${Stack}: $messages" }
    $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
    if (-not $config.settings.local_azure_lab -or $config.env.ARM_METADATA_HOSTNAME -ne 'localhost:4577') { throw 'This script requires the local Floci Azure stack.' }
    $environment = [string]$config.vars.environment
    $subscription = [string]$config.env.ARM_SUBSCRIPTION_ID
    $url = "http://localhost:4577/subscriptions/$subscription/resourceGroups/$environment-rg/providers/Microsoft.ContainerService/managedClusters/$environment-aks/listClusterAdminCredential?api-version=2024-04-01"
    $credentials = Invoke-RestMethod -NoProxy -Uri $url -Method Post -ContentType 'application/json' -Body '{}'
    if (-not $credentials.kubeconfigs[0].value) { throw 'Floci Azure returned no kubeconfig.' }
    $path = Join-Path $root ".local-runtime/kubeconfig-$Stack.yaml"
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $kubeconfig = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($credentials.kubeconfigs[0].value))
    # Floci returns a Docker-only hostname. Use this cluster's published API port on Windows.
    $serverMatch = [regex]::Match($kubeconfig, '(?m)^\s*server:\s*https://([a-zA-Z0-9-]+):6443\s*$')
    if (-not $serverMatch.Success) { throw 'Unexpected Floci Azure kubeconfig server.' }
    $containerName = $serverMatch.Groups[1].Value
    $containerJson = & docker inspect $containerName
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect Azure Kubernetes container $containerName." }
    $container = ($containerJson | ConvertFrom-Json)[0]
    if ($container.Config.Labels.'io.floci.resource-id' -ne "$environment-aks") { throw 'Azure Kubernetes container belongs to another cluster.' }
    $apiPort = $container.NetworkSettings.Ports.'6443/tcp'[0].HostPort
    if (-not $apiPort) { throw 'Azure Kubernetes API has no published port.' }
    $kubeconfig = $kubeconfig.Replace("https://${containerName}:6443", "https://localhost:$apiPort")
    [IO.File]::WriteAllText($path, $kubeconfig)
    $env:NO_PROXY = ((@($env:NO_PROXY -split ',') + @('localhost','127.0.0.1','::1')) | Where-Object { $_ } | Select-Object -Unique) -join ','
    kubectl --kubeconfig $path wait --for=condition=Ready nodes --all --timeout=180s
    if ($LASTEXITCODE -ne 0) { throw 'Azure Kubernetes nodes are not ready.' }
    kubectl --kubeconfig $path rollout status deployment/coredns -n kube-system --timeout=180s
    if ($LASTEXITCODE -ne 0) { throw 'Azure Kubernetes DNS is not ready.' }
    Write-Host "$Stack is ready. Kubeconfig: $path"
} finally {
    if (Test-Path -LiteralPath $configFile) { Remove-Item -LiteralPath $configFile -Force }
    Pop-Location
}
