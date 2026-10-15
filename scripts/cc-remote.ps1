param(
  [string]$PublicOrigin = "",
  [string]$WorkspaceDir = "",
  [string]$DeviceName = "My PC",
  [int]$Port = 8787,
  [switch]$NoTunnel,
  [switch]$AllowBypassPermissions,
  [switch]$DisableBypassPermissions
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runDir = Join-Path $root ".run"
$tunnelConfig = Join-Path $runDir "cloudflared-cc-remote.yml"
$tunnelOut = Join-Path $runDir "cloudflared.out.log"
$tunnelErr = Join-Path $runDir "cloudflared.err.log"
$tunnelProcess = $null

if ([string]::IsNullOrWhiteSpace($PublicOrigin) -and
    -not [string]::IsNullOrWhiteSpace($env:PUBLIC_ORIGIN)) {
  $PublicOrigin = $env:PUBLIC_ORIGIN
}

if ([string]::IsNullOrWhiteSpace($PublicOrigin) -and
    -not $NoTunnel -and
    (Test-Path $tunnelConfig)) {
  $hostnameLine = Select-String `
    -LiteralPath $tunnelConfig `
    -Pattern '^\s*-\s*hostname:\s*(?<hostname>[^#\s]+)' |
    Select-Object -First 1

  if ($hostnameLine) {
    $hostname = $hostnameLine.Matches[0].Groups['hostname'].Value.Trim([char[]]@("'", '"'))
    if (-not [string]::IsNullOrWhiteSpace($hostname)) {
      $PublicOrigin = "https://$hostname"
    }
  }

  if ([string]::IsNullOrWhiteSpace($PublicOrigin)) {
    throw "Could not determine PUBLIC_ORIGIN from $tunnelConfig. Pass -PublicOrigin explicitly."
  }
}

if ([string]::IsNullOrWhiteSpace($WorkspaceDir)) {
  $WorkspaceDir = (Get-Location).Path
}

$healthUrl = "http://127.0.0.1:$Port/api/health"
$registerUrl = "http://127.0.0.1:$Port/api/local/projects/register"
$localControlPath = Join-Path $root ".data\local-control.json"
$daemonDetected = $false

try {
  $health = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 2
  if ($health.ok -eq $true) {
    $daemonDetected = $true
    if ($health.service -ne "cc-remote") {
      throw "An older CC Remote daemon is running. Stop it once, then run cc-remote again."
    }
    if (-not (Test-Path $localControlPath)) {
      throw "CC Remote is running, but the local control token is missing."
    }
    $localControl = Get-Content -Raw $localControlPath | ConvertFrom-Json
    $localControl = Get-Content -Raw $localControlPath | ConvertFrom-Json
    $headers = @{ "X-CC-Remote-Local-Token" = $localControl.token }
    # Windows PowerShell 5.1 encodes a JSON *string* body as Latin-1, turning
    # non-ASCII workspace paths into "????" and causing a 500 from the daemon.
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ path = $WorkspaceDir } | ConvertTo-Json))
    $result = Invoke-RestMethod `
      -Uri $registerUrl `
      -Method Post `
      -Headers $headers `
      -ContentType "application/json; charset=utf-8" `
      -Body $bodyBytes `
      -TimeoutSec 10
    Write-Host "CC Remote is already running."
    Write-Host "Active workspace: $WorkspaceDir"
    exit 0
  }
} catch {
  if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 409) {
    throw "Claude is running. Stop the current task before switching projects."
  }
  if ($daemonDetected) { throw }
}

function Stop-Tunnel {
  if ($script:tunnelProcess -and -not $script:tunnelProcess.HasExited) {
    Write-Host "Stopping cloudflared pid=$($script:tunnelProcess.Id)"
    Stop-Process -Id $script:tunnelProcess.Id -Force -ErrorAction SilentlyContinue
    $script:tunnelProcess.WaitForExit(5000) | Out-Null
  }
}

New-Item -ItemType Directory -Force -Path $runDir | Out-Null

try {
  if (-not $NoTunnel) {
    $cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cloudflared) {
      throw "cloudflared not found in PATH. Install cloudflared or run with -NoTunnel."
    }

    Remove-Item $tunnelOut, $tunnelErr -Force -ErrorAction SilentlyContinue

    if (Test-Path $tunnelConfig) {
      $tunnelArgs = @("tunnel", "--config", $tunnelConfig, "run")
    } else {
      $tunnelArgs = @("tunnel", "--url", "http://127.0.0.1:$Port")
    }

    $script:tunnelProcess = Start-Process `
      -FilePath $cloudflared.Source `
      -ArgumentList $tunnelArgs `
      -WorkingDirectory $root `
      -RedirectStandardOutput $tunnelOut `
      -RedirectStandardError $tunnelErr `
      -NoNewWindow `
      -PassThru

    Write-Host "cloudflared pid=$($script:tunnelProcess.Id)"
    Write-Host "cloudflared logs: $tunnelOut"
  }

  $env:PUBLIC_ORIGIN = $PublicOrigin
  $env:WORKSPACE_DIR = $WorkspaceDir
  $env:DEVICE_NAME = $DeviceName
  $env:PORT = "$Port"
  $env:ALLOW_BYPASS_PERMISSIONS = if ($DisableBypassPermissions) { "0" } else { "1" }

  Write-Host "PUBLIC_ORIGIN=$env:PUBLIC_ORIGIN"
  Write-Host "WORKSPACE_DIR=$env:WORKSPACE_DIR"
  Write-Host "DEVICE_NAME=$env:DEVICE_NAME"
  Write-Host "ALLOW_BYPASS_PERMISSIONS=$env:ALLOW_BYPASS_PERMISSIONS"
  Write-Host "Starting daemon. Press Ctrl+C to stop daemon and tunnel."

  Push-Location $root
  try {
    npm run dev
    if ($LASTEXITCODE) {
      exit $LASTEXITCODE
    }
  } finally {
    Pop-Location
  }
} finally {
  Stop-Tunnel
}
