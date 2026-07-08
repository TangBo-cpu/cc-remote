param(
  [string]$PublicOrigin = "https://tbhaoshuai.ccwu.cc",
  [string]$WorkspaceDir = "",
  [string]$DeviceName = "tb",
  [int]$Port = 8787,
  [switch]$NoTunnel
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$runDir = Join-Path $root ".run"
$tunnelConfig = Join-Path $runDir "cloudflared-cc-remote.yml"
$tunnelOut = Join-Path $runDir "cloudflared.out.log"
$tunnelErr = Join-Path $runDir "cloudflared.err.log"
$tunnelProcess = $null

if ([string]::IsNullOrWhiteSpace($WorkspaceDir)) {
  $WorkspaceDir = $root
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

  Write-Host "PUBLIC_ORIGIN=$env:PUBLIC_ORIGIN"
  Write-Host "WORKSPACE_DIR=$env:WORKSPACE_DIR"
  Write-Host "DEVICE_NAME=$env:DEVICE_NAME"
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
