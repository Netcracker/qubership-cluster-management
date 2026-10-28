#requires -Version 7.0
param(
    [switch]$Initialize,
    [switch]$RenderHelmfile,
    [string]$Stack = 'customer1-aws-staging'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $projectRoot
try {
    atmos validate stacks
    if ($LASTEXITCODE -ne 0) { throw 'Atmos stack validation failed.' }
    terraform fmt -check -recursive components/terraform
    if ($LASTEXITCODE -ne 0) { throw 'Terraform formatting check failed.' }

    $modules = Get-ChildItem components/terraform -Filter versions.tf -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]\.terraform[\\/]' }
    foreach ($module in $modules) {
        Push-Location $module.DirectoryName
        try {
            if ($Initialize) {
                terraform init -backend=false -input=false -no-color
                if ($LASTEXITCODE -ne 0) { throw "Initialization failed: $($module.DirectoryName)" }
            }
            terraform validate -no-color
            if ($LASTEXITCODE -ne 0) { throw "Validation failed: $($module.DirectoryName)" }
        } finally { Pop-Location }
    }

    Get-ChildItem local/scripts -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } | ForEach-Object {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count) { throw "PowerShell parsing failed: $($_.Name): $parseErrors" }
    }
    if ($RenderHelmfile) {
        foreach ($component in 'istio', 'argocd', 'kiali', 'minio', 'headlamp') {
            atmos helmfile template $component -s $Stack --skip-deps | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Helmfile render failed: $component" }
        }
    }
    Write-Host 'Configuration checks passed. No infrastructure changes were applied.'
} finally { Pop-Location }
