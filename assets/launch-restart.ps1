param(
  [Parameter(Mandatory = $true)][int]$MainPid,
  [Parameter(Mandatory = $true)][string]$Exe,
  [string]$Lock = '',
  [string]$LogPath = ''
)

# Starts restart.ps1 outside the application's process tree.
#
# restart.ps1 kills the whole shell tree with `taskkill /T`, so it cannot itself be a child of
# that tree: it would kill itself before it could start the executable again. A process created
# through WMI runs under WmiPrvSE instead, outside the job, and survives the kill.

$ErrorActionPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'hidden-process.ps1')

function Write-Log([string]$Message) {
  if (-not $LogPath) { return }
  try {
    $line = '{0:yyyy-MM-dd HH:mm:ss} [launch {1}] {2}' -f (Get-Date), $PID, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
  } catch { }
}

$restartScript = Join-Path $PSScriptRoot 'restart.ps1'
$parts = @(
  'powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
  '-File', ('"{0}"' -f $restartScript),
  '-MainPid', "$MainPid",
  '-Exe', ('"{0}"' -f $Exe)
)
if ($Lock) { $parts += @('-Lock', ('"{0}"' -f $Lock)) }
$command = $parts -join ' '

Write-Log "requesting restart for shell $MainPid"
try {
  $result = New-HiddenProcess -CommandLine $command
  if ($result.ReturnValue -eq 0) {
    Write-Log "restarter created outside the app job, pid $($result.ProcessId)"
    exit 0
  }
  Write-Log "Win32_Process.Create returned $($result.ReturnValue)"
} catch {
  Write-Log "WMI creation failed: $($_.Exception.Message)"
}

# No fallback on purpose: a child of the shell would be killed by the restarter's own taskkill.
exit 1
