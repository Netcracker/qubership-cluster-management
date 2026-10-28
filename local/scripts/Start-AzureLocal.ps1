#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $root
try {
    docker compose -f ./local/compose.azure.yml up -d
    if ($LASTEXITCODE -ne 0) { throw 'Cannot start Floci Azure.' }
    New-Item -ItemType Directory -Path ./.local-runtime -Force | Out-Null
    $certificate = Join-Path $root '.local-runtime/floci-azure.crt'
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        curl.exe --noproxy '*' --fail --silent --max-time 3 http://localhost:4577/_floci/tls-cert --output $certificate
        if ($LASTEXITCODE -eq 0 -and (Get-Content -LiteralPath $certificate -Raw) -match 'BEGIN CERTIFICATE') { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'Floci Azure TLS certificate is not available.' }
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate)
    if (-not (Test-Path "Cert:\CurrentUser\Root\$($cert.Thumbprint)")) {
        Import-Certificate -FilePath $certificate -CertStoreLocation Cert:\CurrentUser\Root | Out-Null
    }
    Write-Host 'Floci Azure is ready at https://localhost:4577; its CA is trusted for the current Windows user.'
} finally { Pop-Location }
