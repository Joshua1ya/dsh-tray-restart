# Starts a process outside the desktop application's job object without ever showing a console.
#
# The desktop shell puts the host process into a job object that restricts USER handles, so a
# process started as a normal child of the host cannot register a tray icon. A process created
# through WMI runs under WmiPrvSE instead, outside that job.
#
# WMI creation has no CREATE_NO_WINDOW flag, so a plain Win32_Process.Create leaves the console
# window visible for a moment - on Windows 11 with Windows Terminal as the default terminal that
# is a full terminal window popping up. Passing Win32_ProcessStartup with ShowWindow = 0 creates
# the console hidden, so nothing flashes.

function New-HiddenProcess {
  param([Parameter(Mandatory = $true)][string]$CommandLine)

  $startup = $null
  try {
    $startup = ([wmiclass]'Win32_ProcessStartup').CreateInstance()
    $startup.ShowWindow = 0
  } catch {
    $startup = $null
  }

  if ($startup) {
    try {
      return ([wmiclass]'Win32_Process').Create($CommandLine, $null, $startup)
    } catch {
      # Fall through to the plain call below.
    }
  }

  # Last resort: a console window may flash, but the process still lands outside the job.
  return Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $CommandLine } -ErrorAction Stop
}
