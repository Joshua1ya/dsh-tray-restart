param(
  [Parameter(Mandatory = $true)][int]$MainPid,
  [Parameter(Mandatory = $true)][string]$Exe,
  [string]$Lock = ''
)

# Detached restarter: spawns outside the app's process tree, kills the shell (which takes the
# host and every child with it), clears a stale profile lock, then starts the executable again.

$ErrorActionPreference = 'SilentlyContinue'
$log = Join-Path $env:TEMP 'dsh-tray-restart.log'

function Write-Log([string]$Message) {
  try {
    Add-Content -LiteralPath $log -Value ('{0:yyyy-MM-dd HH:mm:ss} [restart {1}] {2}' -f (Get-Date), $PID, $Message) -Encoding UTF8
  } catch { }
}

Write-Log "restarting shell $MainPid -> $Exe"

if (-not (Get-Process -Id $MainPid -ErrorAction SilentlyContinue)) {
  Write-Log 'shell already gone; only relaunching'
} else {
  & taskkill.exe /PID $MainPid /T /F | Out-Null
  for ($i = 0; $i -lt 60; $i++) {
    if (-not (Get-Process -Id $MainPid -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 200
  }
  Write-Log "shell $MainPid stopped"
}

# A forced kill skips the normal quit path, so the profile lock file can outlive the process.
if ($Lock -and (Test-Path -LiteralPath $Lock)) {
  try {
    Remove-Item -LiteralPath $Lock -Force -ErrorAction Stop
    Write-Log 'stale profile lock removed'
  } catch {
    Write-Log "could not remove lock: $($_.Exception.Message)"
  }
}

Start-Sleep -Milliseconds 500

try {
  Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe) -ErrorAction Stop
  Write-Log 'relaunched'
} catch {
  Write-Log "relaunch failed: $($_.Exception.Message)"
}
