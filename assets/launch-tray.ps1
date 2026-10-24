param(
  [Parameter(Mandatory = $true)][int]$MainPid,
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Icon,
  [string]$Lock = '',
  [string]$LogPath = '',
  [string]$PidFile = ''
)

# Starts tray.ps1 outside the application's process tree.
#
# The desktop shell puts the host process into a Job object that restricts USER handles, so a
# process started as a normal child of the host can create a NotifyIcon without error but never
# makes it onto the notification area (it is invisible to the shell). A process created through
# WMI runs under WmiPrvSE instead, outside that job, and registers normally.

$ErrorActionPreference = 'SilentlyContinue'

function Write-Log([string]$Message) {
  if (-not $LogPath) { return }
  try {
    $line = '{0:yyyy-MM-dd HH:mm:ss} [launch {1}] {2}' -f (Get-Date), $PID, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
  } catch { }
}

$trayScript = Join-Path $PSScriptRoot 'tray.ps1'
$parts = @(
  'powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
  '-File', ('"{0}"' -f $trayScript),
  '-MainPid', "$MainPid",
  '-Exe', ('"{0}"' -f $Exe),
  '-Icon', ('"{0}"' -f $Icon)
)
if ($Lock) { $parts += @('-Lock', ('"{0}"' -f $Lock)) }
if ($LogPath) { $parts += @('-LogPath', ('"{0}"' -f $LogPath)) }
if ($PidFile) { $parts += @('-PidFile', ('"{0}"' -f $PidFile)) }
$command = $parts -join ' '

Write-Log "requesting tray for shell $MainPid"
Write-Log "command: $command"
$spawned = $false
try {
  $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command } -ErrorAction Stop
  if ($result.ReturnValue -eq 0) {
    $spawned = $true
    Write-Log "tray created outside the app job, pid $($result.ProcessId)"
  } else {
    Write-Log "Win32_Process.Create returned $($result.ReturnValue)"
  }
} catch {
  Write-Log "WMI creation failed: $($_.Exception.Message)"
}

if (-not $spawned) {
  # Last resort: a child of the host. The icon may not reach the notification area.
  try {
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList ($parts[1..($parts.Count - 1)] -join ' ') -ErrorAction Stop
    Write-Log 'tray started as a child process (icon may not appear)'
  } catch {
    Write-Log "fallback start failed: $($_.Exception.Message)"
  }
}
