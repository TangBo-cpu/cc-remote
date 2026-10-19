$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
try {
  & npm.cmd run build
  if ($LASTEXITCODE -ne 0) { throw 'Daemon build failed.' }
  & cargo build --release --locked --manifest-path (Join-Path $root 'desktop\Cargo.toml')
  if ($LASTEXITCODE -ne 0) { throw 'Desktop build failed.' }
  $output = Join-Path $root 'cc-remote-desktop.exe'
  Copy-Item -LiteralPath (Join-Path $root 'desktop\target\release\cc-remote-desktop.exe') -Destination $output -Force
  Write-Output "Desktop launcher: $output"
} finally {
  Pop-Location
}
