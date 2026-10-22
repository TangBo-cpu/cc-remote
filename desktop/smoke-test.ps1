param([string]$Executable = (Join-Path $PSScriptRoot '..\cc-remote-desktop.exe'))

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runRoot = Join-Path $repo '.run'
$fixture = Join-Path $runRoot ('desktop-smoke-' + [guid]::NewGuid().ToString('N'))
$launcher = $null
$oldPort = $env:PORT
$oldOrigin = $env:PUBLIC_ORIGIN
$oldDevice = $env:DEVICE_NAME

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LauncherSmokeNative {
    public delegate bool EnumWindowCallback(IntPtr window, IntPtr param);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowCallback callback, IntPtr param);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint id);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    public static IntPtr MainWindow(uint processId) {
      IntPtr found = IntPtr.Zero;
      EnumWindows((window, param) => {
        uint id; GetWindowThreadProcessId(window, out id);
        if (id == processId && IsWindowVisible(window)) { found = window; return false; }
        return true;
      }, IntPtr.Zero);
      return found;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string name, string title);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string name, string title);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int capacity);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr window, int id);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)] public static extern IntPtr SendText(IntPtr window, uint message, IntPtr wparam, string text);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr window, IntPtr rect, IntPtr region, uint flags);
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flags);
    [DllImport("user32.dll", EntryPoint="GetClassLongPtrW")] public static extern IntPtr GetClassLongPtr(IntPtr window, int index);
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, uint count);
}
'@
[LauncherSmokeNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

function Assert-Launcher($condition, [string]$message) {
  if (-not $condition) { throw $message }
}

function Wait-LauncherWindow($process) {
  $deadline = [datetime]::UtcNow.AddSeconds(10)
  do {
    $process.Refresh()
    if ($process.HasExited) { throw 'Launcher exited before opening its window.' }
    $currentWindow = [LauncherSmokeNative]::MainWindow($process.Id)
    if ($currentWindow -ne [IntPtr]::Zero) { return $currentWindow }
    $hostWindow = [LauncherSmokeNative]::FindWindow('CCRemoteNativeLauncher', "CCRemoteNativeLauncher-$env:PORT")
    if ($hostWindow -ne [IntPtr]::Zero) {
      [LauncherSmokeNative]::SendMessage($hostWindow, 0x8003, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    }
    Start-Sleep -Milliseconds 100
  } while ([datetime]::UtcNow -lt $deadline)
  throw 'Launcher window timeout.'
}

function Read-LauncherStatus {
  $control = Get-Content -LiteralPath (Join-Path $fixture '.data\local-control.json') -Raw | ConvertFrom-Json
  Invoke-RestMethod -Uri "$baseUrl/api/local/status" -Headers @{ 'X-CC-Remote-Local-Token' = $control.token } -TimeoutSec 2
}

function Wait-LauncherStatus {
  $deadline = [datetime]::UtcNow.AddSeconds(15)
  do {
    $launcher.Refresh()
    if ($launcher.HasExited) {
      $failureLog = Get-Content -LiteralPath (Join-Path $fixture 'launcher.err') -Raw -ErrorAction SilentlyContinue
      throw "Launcher exited during startup ($($launcher.ExitCode)): $failureLog"
    }
    try { return Read-LauncherStatus } catch { Start-Sleep -Milliseconds 100 }
  } while ([datetime]::UtcNow -lt $deadline)
  $texts = @()
  $child = [IntPtr]::Zero
  do {
    $child = [LauncherSmokeNative]::FindWindowEx($window, $child, 'STATIC', $null)
    if ($child -ne [IntPtr]::Zero) {
      $text = [System.Text.StringBuilder]::new(4096)
      [LauncherSmokeNative]::GetWindowText($child, $text, $text.Capacity) | Out-Null
      $texts += $text.ToString()
    }
  } while ($child -ne [IntPtr]::Zero)
  $failureLog = Get-Content -LiteralPath (Join-Path $fixture 'launcher.err') -Raw -ErrorAction SilentlyContinue
  throw ('Daemon startup timeout: ' + ($texts -join ' | ') + ' ' + $failureLog)
}

function Exit-Launcher($process, $window) {
  [LauncherSmokeNative]::SendMessage($window, 0x0111, [IntPtr]106, [IntPtr]::Zero) | Out-Null
  if (-not $process.WaitForExit(10000)) {
    $failureLog = Get-Content -LiteralPath (Join-Path $fixture 'launcher.err') -Raw -ErrorAction SilentlyContinue
    $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    $process.Refresh()
    throw "Launcher did not exit cleanly: pid=$($process.Id) alive=$($null -ne $live) exited=$($process.HasExited) $failureLog"
  }
  Assert-Launcher ($process.ExitCode -eq 0) 'Launcher returned a failure exit code.'
}

function Read-LauncherText($window, [int]$id) {
  $text = [System.Text.StringBuilder]::new(4096)
  [LauncherSmokeNative]::GetWindowText([LauncherSmokeNative]::GetDlgItem($window, $id), $text, $text.Capacity) | Out-Null
  $text.ToString()
}

function Save-LauncherScreenshot($window, [string]$name) {
  [LauncherSmokeNative]::RedrawWindow($window, [IntPtr]::Zero, [IntPtr]::Zero, 0x185) | Out-Null
  $rect = [LauncherSmokeNative+Rect]::new()
  [LauncherSmokeNative]::GetWindowRect($window, [ref]$rect) | Out-Null
  $bitmap = [System.Drawing.Bitmap]::new($rect.Right - $rect.Left, $rect.Bottom - $rect.Top)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $dc = $graphics.GetHdc()
  try { Assert-Launcher ([LauncherSmokeNative]::PrintWindow($window, $dc, 2)) 'Window screenshot failed.' }
  finally { $graphics.ReleaseHdc($dc) }
  $exitRect = [LauncherSmokeNative+Rect]::new()
  [LauncherSmokeNative]::GetWindowRect([LauncherSmokeNative]::GetDlgItem($window, 106), [ref]$exitRect) | Out-Null
  $captionPixels = 0
  for ($y = $exitRect.Top - $rect.Top + 8; $y -lt $exitRect.Bottom - $rect.Top - 8; $y += 2) {
    for ($x = $exitRect.Left - $rect.Left + 8; $x -lt $exitRect.Right - $rect.Left - 8; $x += 2) {
      $pixel = $bitmap.GetPixel($x, $y)
      if ($pixel.R -lt 80 -and $pixel.G -lt 80 -and $pixel.B -lt 80) { $captionPixels++ }
    }
  }
  Assert-Launcher ($captionPixels -gt 4) 'Exit button caption was not rendered.'
  $path = Join-Path $runRoot $name
  try { $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) }
  finally { $graphics.Dispose(); $bitmap.Dispose() }
  $path
}

try {
  New-Item -ItemType Directory -Path (Join-Path $fixture 'src'),(Join-Path $fixture 'dist\src'),(Join-Path $fixture '测试项目') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $fixture 'package.json') -Value '{"name":"cc-remote","type":"module"}' -Encoding utf8
  Set-Content -LiteralPath (Join-Path $fixture 'src\daemon.ts') -Value '// Isolated launcher fixture.' -Encoding utf8
  $daemonUri = ([uri](Join-Path $repo 'dist\src\daemon.js')).AbsoluteUri | ConvertTo-Json -Compress
  $daemonWrapper = 'process.env.CLAUDE_BIN = "cc-remote-test-missing"; process.env.CODEX_BIN = "cc-remote-test-missing"; await import(' + $daemonUri + ');'
  Set-Content -LiteralPath (Join-Path $fixture 'dist\src\daemon.js') -Value $daemonWrapper -Encoding utf8
  $fixtureExe = Join-Path $fixture 'cc-remote-desktop.exe'
  Copy-Item -LiteralPath $Executable -Destination $fixtureExe
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, (Get-Random -Minimum 18000 -Maximum 24000))
  $listener.Start()
  $env:PORT = [string]$listener.LocalEndpoint.Port
  $listener.Stop()
  $env:PUBLIC_ORIGIN = ''
  $env:DEVICE_NAME = '测试电脑 🖥'
  $baseUrl = "http://127.0.0.1:$env:PORT"
  $launcher = Start-Process -FilePath $fixtureExe -WindowStyle Hidden -RedirectStandardError (Join-Path $fixture 'launcher.err') -PassThru
  $window = Wait-LauncherWindow $launcher
  Assert-Launcher ([LauncherSmokeNative]::ExtractIconEx($fixtureExe, -1, $null, $null, 0) -eq 1) 'Executable icon resource is missing.'
  Assert-Launcher ([LauncherSmokeNative]::GetClassLongPtr($window, -14) -ne [IntPtr]::Zero) 'Window icon is missing.'
  Assert-Launcher ([LauncherSmokeNative]::GetClassLongPtr($window, -34) -ne [IntPtr]::Zero) 'Small window / tray icon is missing.'
  Save-LauncherScreenshot $window 'desktop-launcher-idle.png' | Out-Null
  [LauncherSmokeNative]::SendMessage($window, 0x0111, [IntPtr]101, [IntPtr]::Zero) | Out-Null
  $deadline = [datetime]::UtcNow.AddSeconds(5)
  do {
    $errorText = Read-LauncherText $window 207
    if ($errorText -eq '请选择一个存在的项目文件夹。') { break }
    Start-Sleep -Milliseconds 100
  } while ([datetime]::UtcNow -lt $deadline)
  Assert-Launcher ($errorText -eq '请选择一个存在的项目文件夹。') 'Invalid workspace error was not shown.'
  Save-LauncherScreenshot $window 'desktop-launcher-error.png' | Out-Null
  $title = [System.Text.StringBuilder]::new(1024)
  [LauncherSmokeNative]::GetWindowText($window, $title, $title.Capacity) | Out-Null
  Assert-Launcher ([LauncherSmokeNative]::GetDlgItem($window, 201) -ne [IntPtr]::Zero) ("Project control missing from window: " + $title.ToString())
  Assert-Launcher ([LauncherSmokeNative]::SendText([LauncherSmokeNative]::GetDlgItem($window, 201), 0x000C, [IntPtr]::Zero, (Join-Path $fixture '测试项目')) -ne [IntPtr]::Zero) 'Setting the project path failed.'
  [LauncherSmokeNative]::SendMessage([LauncherSmokeNative]::GetDlgItem($window, 203), 0x00F1, [IntPtr]1, [IntPtr]::Zero) | Out-Null
  [LauncherSmokeNative]::SendMessage($window, 0x0111, [IntPtr]101, [IntPtr]::Zero) | Out-Null
  $status = Wait-LauncherStatus
  Assert-Launcher (-not $status.paired) 'Fixture unexpectedly paired.'
  Assert-Launcher ($status.pairing.modules.Count -ge 21) 'QR matrix missing.'
  Assert-Launcher ($status.workspaceDir -eq (Join-Path $fixture '测试项目')) 'Unicode workspace was not preserved.'
  Start-Sleep -Milliseconds 500
  $launcher.Refresh()
  $windowMiB = [math]::Round($launcher.WorkingSet64 / 1MB, 2)
  $windowPrivateMiB = [math]::Round($launcher.PrivateMemorySize64 / 1MB, 2)
  $windowGdi = [LauncherSmokeNative]::GetGuiResources($launcher.Handle, 0)
  $second = Start-Process -FilePath $fixtureExe -WindowStyle Hidden -PassThru
  Assert-Launcher ($second.WaitForExit(5000)) 'Second launcher instance stayed running.'
  Assert-Launcher ($second.ExitCode -eq 0) 'Second launcher instance failed.'
  $screenshot = Save-LauncherScreenshot $window 'desktop-launcher-smoke.png'
  [LauncherSmokeNative]::SendMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
  Start-Sleep -Milliseconds 500
  $launcher.Refresh()
  Assert-Launcher (-not $launcher.HasExited) 'Closing the window stopped the launcher.'
  Assert-Launcher ((Invoke-RestMethod -Uri "$baseUrl/api/health").ok) 'Closing the window stopped the daemon.'
  $trayMiB = [math]::Round($launcher.WorkingSet64 / 1MB, 2)
  $trayPrivateMiB = [math]::Round($launcher.PrivateMemorySize64 / 1MB, 2)
  $trayGdi = [LauncherSmokeNative]::GetGuiResources($launcher.Handle, 0)
  Assert-Launcher ($trayGdi -lt $windowGdi) 'Window GDI resources were not released.'
  $pairBody = @{ nonce = $status.pairing.payload.nonce } | ConvertTo-Json -Compress
  $paired = Invoke-RestMethod -Uri "$baseUrl/api/pair" -Method Post -ContentType 'application/json' -Body $pairBody
  Assert-Launcher (-not [string]::IsNullOrEmpty($paired.token)) 'Pairing failed.'
  $hostWindow = [LauncherSmokeNative]::FindWindow('CCRemoteNativeLauncher', "CCRemoteNativeLauncher-$env:PORT")
  [LauncherSmokeNative]::SendMessage($hostWindow, 0x8003, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
  $window = Wait-LauncherWindow $launcher
  Exit-Launcher $launcher $window
  Assert-Launcher ($null -eq (Get-Process -Id $status.processId -ErrorAction SilentlyContinue)) 'Owned daemon was left running.'
  $hashBefore = (Get-Content -LiteralPath (Join-Path $fixture '.data\state.json') -Raw | ConvertFrom-Json).tokenHash
  $launcher = Start-Process -FilePath $fixtureExe -WindowStyle Hidden -RedirectStandardError (Join-Path $fixture 'launcher.err') -PassThru
  $window = Wait-LauncherWindow $launcher
  $restored = Wait-LauncherStatus
  Assert-Launcher $restored.paired 'Pairing was lost on restart.'
  Assert-Launcher ($null -eq $restored.pairing) 'Restart required a new QR pairing.'
  $authorized = Invoke-RestMethod -Uri "$baseUrl/api/status" -Headers @{ Authorization = "Bearer $($paired.token)" }
  Assert-Launcher $authorized.authorized 'Original phone token no longer works.'
  $hashAfter = (Get-Content -LiteralPath (Join-Path $fixture '.data\state.json') -Raw | ConvertFrom-Json).tokenHash
  Assert-Launcher ($hashBefore -eq $hashAfter) 'Restart replaced the phone token.'
  Start-Sleep -Milliseconds 300
  Save-LauncherScreenshot $window 'desktop-launcher-paired.png' | Out-Null
  Exit-Launcher $launcher $window
  [pscustomobject]@{ Result = 'PASS'; WindowWorkingSetMiB = $windowMiB; WindowPrivateMiB = $windowPrivateMiB; TrayWorkingSetMiB = $trayMiB; TrayPrivateMiB = $trayPrivateMiB; WindowGdiObjects = $windowGdi; TrayGdiObjects = $trayGdi; Screenshot = $screenshot } | ConvertTo-Json
} finally {
  if ($launcher -and -not $launcher.HasExited) {
    Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue
    $launcher.WaitForExit(5000) | Out-Null
  }
  $env:PORT = $oldPort
  $env:PUBLIC_ORIGIN = $oldOrigin
  $env:DEVICE_NAME = $oldDevice
  $resolvedFixture = [System.IO.Path]::GetFullPath($fixture)
  $resolvedRun = [System.IO.Path]::GetFullPath($runRoot) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $resolvedFixture.StartsWith($resolvedRun, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
  if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
