#requires -Version 7.0
param([Parameter(Mandatory)][string]$Stack)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Local-Lab.psm1') -Force -DisableNameChecking
Push-Location (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
try { Prepare-LabCluster -Stack $Stack } finally { Pop-Location }
