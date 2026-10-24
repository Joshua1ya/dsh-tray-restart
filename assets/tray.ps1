param(
  [Parameter(Mandatory = $true)][int]$MainPid,
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Icon,
  [string]$Lock = '',
  [string]$LogPath = '',
  [string]$PidFile = ''
)

# Windows notification-area helper for DeepSeek Harness.
# Right-click the icon for: restart app + host, open the app, reload the window, quit the icon.

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Write-Log([string]$Message) {
  if (-not $LogPath) { return }
  try {
    $line = '{0:yyyy-MM-dd HH:mm:ss} [tray {1}] {2}' -f (Get-Date), $PID, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
  } catch { }
}

function Test-MainAlive {
  return [bool](Get-Process -Id $MainPid -ErrorAction SilentlyContinue)
}

if (-not (Test-MainAlive)) {
  Write-Log "shell $MainPid is gone at startup; exiting"
  exit 0
}

Write-Log "params: Icon='$Icon' Exe='$Exe'"

# Records "<tray pid> <shell pid>" so a restarted shell can tell its own icon from a leftover one.
if ($PidFile) {
  try { Set-Content -LiteralPath $PidFile -Value "$PID $MainPid" -Encoding ASCII } catch { }
}

# Note: PowerShell variables are case-insensitive, so the image must not live in $icon — that would
# overwrite the -Icon parameter and the path would be gone before it is used.
$iconImage = [System.Drawing.SystemIcons]::Application
if (Test-Path -LiteralPath $Icon) {
  try {
    $iconImage = New-Object System.Drawing.Icon -ArgumentList $Icon
    Write-Log "icon loaded $($iconImage.Width)x$($iconImage.Height)"
  } catch {
    Write-Log "icon load failed, using the default: $($_.Exception.Message)"
  }
} else {
  Write-Log "icon missing at $Icon, using the default"
}

$notify = $null
try {
  $notify = New-Object System.Windows.Forms.NotifyIcon
  $notify.Icon = $iconImage
  $notify.Text = 'DeepSeek Harness · 右键重启'
  $notify.Visible = $true
  Write-Log "notify icon visible=$($notify.Visible)"
} catch {
  Write-Log "notify icon setup failed: $($_.Exception.Message)"
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip

# Restart: hand the kill+relaunch to a detached helper (spawned through WMI so it is not a child
# of this app's process tree and survives the tree being killed), then drop this icon.
$restartScript = Join-Path $PSScriptRoot 'restart.ps1'
$restartItem = New-Object System.Windows.Forms.ToolStripMenuItem
$restartItem.Text = '重启 DSH（应用 + Host）'
$restartItem.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)
$restartItem.Add_Click({
  Write-Log 'restart requested'
  $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -MainPid {1} -Exe "{2}" -Lock "{3}"' -f $restartScript, $MainPid, $Exe, $Lock
  $spawned = $false
  try {
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command } -ErrorAction Stop
    if ($result.ReturnValue -eq 0) { $spawned = $true; Write-Log "restarter spawned via WMI pid $($result.ProcessId)" }
  } catch {
    Write-Log "WMI spawn failed: $($_.Exception.Message)"
  }
  if (-not $spawned) {
    try {
      Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $restartScript,
        '-MainPid', "$MainPid", '-Exe', $Exe, '-Lock', $Lock
      ) -ErrorAction Stop
      Write-Log 'restarter spawned via Start-Process'
    } catch {
      Write-Log "fallback spawn failed: $($_.Exception.Message)"
    }
  }
  $notify.Visible = $false
  $notify.Dispose()
  [System.Windows.Forms.Application]::Exit()
})

$openItem = New-Object System.Windows.Forms.ToolStripMenuItem
$openItem.Text = '打开 DeepSeek Harness'
$openItem.Add_Click({
  try { Start-Process -FilePath $Exe -ErrorAction Stop } catch { Write-Log "open failed: $($_.Exception.Message)" }
})

$quitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$quitItem.Text = '退出托盘图标'
$quitItem.Add_Click({
  Write-Log 'tray icon quit by user'
  $notify.Visible = $false
  $notify.Dispose()
  [System.Windows.Forms.Application]::Exit()
})

[void]$menu.Items.Add($restartItem)
[void]$menu.Items.Add($openItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($quitItem)
$notify.ContextMenuStrip = $menu

# Left click focuses the app; a second-invocation of the executable reaches the running
# instance through Electron's single-instance lock and brings its window forward.
$notify.Add_MouseClick({
  param($sender, $eventArgs)
  if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    try { Start-Process -FilePath $Exe -ErrorAction Stop } catch { Write-Log "open failed: $($_.Exception.Message)" }
  }
})

# Follow the application's lifetime: an icon left behind by a crashed shell is just clutter.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
  if (-not (Test-MainAlive)) {
    Write-Log "shell $MainPid exited; removing tray icon"
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
  }
})
$timer.Start()

Write-Log "tray icon up (shell $MainPid, exe $Exe)"
[System.Windows.Forms.Application]::Run()
