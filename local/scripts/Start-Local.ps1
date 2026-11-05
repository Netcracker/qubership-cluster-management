#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$env:HTTPS_PROXY = 'http://127.0.0.1:12334'
$env:HTTP_PROXY = $env:HTTPS_PROXY
$env:NO_PROXY = ((@($env:NO_PROXY -split ',') + @('localhost', '127.0.0.1', '::1', 'floci')) |
    Where-Object { $_ } | Select-Object -Unique) -join ','
Import-Module (Join-Path $PSScriptRoot 'Local-Lab.psm1') -Force -DisableNameChecking
Push-Location (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
try { Start-Lab } finally { Pop-Location }
