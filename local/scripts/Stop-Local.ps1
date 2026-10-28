#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Local-Lab.psm1') -Force -DisableNameChecking
Push-Location (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
try { Stop-Lab } finally { Pop-Location }
