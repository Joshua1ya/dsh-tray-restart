/**
 * Tray Restart — a Windows notification-area icon that restarts DeepSeek Harness.
 *
 * The Electron shell owns the only tray icon it shows, and its menu is built inside the
 * main process, which a host plugin cannot reach. So this plugin runs a small
 * Windows PowerShell (WinForms) helper next to the app that draws its own icon and,
 * on right-click, kills the desktop process tree and starts the executable again.
 *
 * @module dsh-tray-restart
 */
import { spawn } from 'node:child_process'
import { appendFileSync, closeSync, existsSync, openSync, readFileSync, rmSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'tray-restart'
export const inject = []

const HERE = dirname(fileURLToPath(import.meta.url))
const LAUNCH_SCRIPT = join(HERE, 'assets', 'launch-tray.ps1')
const RESTART_LAUNCHER = join(HERE, 'assets', 'launch-restart.ps1')
const PID_FILE = join(tmpdir(), 'dsh-tray-restart.pid')
const LOG_FILE = join(tmpdir(), 'dsh-tray-restart.log')
const SPAWN_LOG = join(tmpdir(), 'dsh-tray-restart.spawn.log')
const ROUTE = '/dsh-tray-restart'

/** Whether a process id is still running. */
function isAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

/** Read the "<tray pid> <shell pid>" a previous run recorded. */
function recorded() {
  try {
    const [tray, shell] = readFileSync(PID_FILE, 'utf8').trim().split(/\s+/u)
    return { tray: Number.parseInt(tray, 10) || 0, shell: Number.parseInt(shell, 10) || 0 }
  } catch {
    return { tray: 0, shell: 0 }
  }
}

/** Kill a process tree, ignoring races. */
function killTree(pid) {
  try {
    spawn('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true })
  } catch {
    /* already gone */
  }
}

/** Resolve the harness home the same way the desktop shell does. */
function dshHome() {
  const override = process.env.DSH_HOME
  return override !== undefined && override.trim().length > 0 ? override : join(homedir(), '.dsh')
}

/** Write a small JSON response. */
function sendJson(res, status, body) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
  })
  res.end(payload)
}

/**
 * Ask Windows to build the restarter outside the app's job object and report whether that
 * request was accepted. The launcher exits once WMI has created the helper, so its exit code
 * says whether the restart is actually under way.
 */
function launchRestart(mainPid, executable, lockPath) {
  return new Promise((resolve) => {
    let settled = false
    let timer
    const finish = (result) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(result)
    }
    let child
    try {
      child = spawn(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          RESTART_LAUNCHER,
          '-MainPid', String(mainPid),
          '-Exe', executable,
          '-Lock', lockPath,
          '-LogPath', LOG_FILE,
        ],
        { cwd: HERE, stdio: 'ignore', windowsHide: true },
      )
    } catch (error) {
      resolve({ ok: false, reason: error?.message ?? String(error) })
      return
    }
    timer = setTimeout(() => {
      child.kill()
      finish({ ok: false, reason: 'launcher did not finish in time' })
    }, 10_000)
    child.on('error', (error) => finish({ ok: false, reason: error.message }))
    child.on('exit', (code) => {
      if (code === 0) finish({ ok: true })
      else finish({ ok: false, reason: `launcher exited with ${code ?? 'no code'}` })
    })
  })
}

/**
 * The one loopback route the header button posts to. Exported so the decision logic (status,
 * method, origin) can be exercised without starting a tray helper or a real restart.
 */
export function createRestartRoute(options) {
  const { mainPid, executable, lockPath, origin, log, launch = launchRestart } = options
  const note = typeof log === 'function' ? log : () => {}
  return {
    kind: 'prefix',
    path: ROUTE,
    async handler(req, res) {
      const url = new URL(req.url ?? '/', 'http://localhost')
      if (url.pathname === `${ROUTE}/status`) {
        const trayPid = recorded().tray
        sendJson(res, 200, {
          ok: true,
          platform: process.platform,
          shellPid: mainPid,
          trayPid: trayPid === 0 ? null : trayPid,
          trayAlive: trayPid !== 0 && isAlive(trayPid),
        })
        return
      }
      if (url.pathname !== `${ROUTE}/restart`) {
        sendJson(res, 404, { ok: false, reason: 'not found' })
        return
      }
      if (req.method !== 'POST') {
        res.setHeader('allow', 'POST')
        sendJson(res, 405, { ok: false, reason: 'method not allowed' })
        return
      }
      // A page on another origin must not be able to restart the app.
      const claimed = req.headers.origin
      if (typeof claimed === 'string' && claimed.length > 0 && claimed !== origin()) {
        sendJson(res, 403, { ok: false, reason: 'cross-origin request refused' })
        return
      }
      const result = await launch(mainPid, executable, lockPath)
      note(result.ok ? 'info' : 'warn', `tray-restart: header restart for shell ${mainPid} (${result.ok ? 'accepted' : result.reason})`)
      sendJson(res, result.ok ? 200 : 500, result)
    },
  }
}

export function apply(ctx) {
  const logger = typeof ctx.logger === 'function' ? ctx.logger('tray-restart') : console
  // The host keeps its log out of reach, so mirror every decision into the helper's own log.
  const log = (level, message) => {
    logger[level]?.(message)
    try {
      appendFileSync(LOG_FILE, `${new Date().toISOString().slice(11, 19)} [host ${process.pid}] ${message}\n`)
    } catch {
      /* logging must never break the plugin */
    }
  }

  const executable = process.execPath
  const resources = join(dirname(executable), 'resources')
  const trayIcon = join(resources, 'tray.ico')

  // Only the packaged Windows desktop app has a shell worth restarting.
  if (process.platform !== 'win32' || !basename(executable).toLowerCase().startsWith('deepseek harness') || !existsSync(trayIcon)) {
    log('info', 'tray-restart: not the Windows desktop runtime, staying idle')
    return
  }

  const mainPid = process.ppid
  if (!isAlive(mainPid)) {
    log('warn', 'tray-restart: no live parent shell process, staying idle')
    return
  }

  const existing = recorded()
  // A helper left from the shell that just exited retires on its own timer, but not before this
  // shell asks for its icon, so clear it out first. A helper of this very shell is reused.
  const trayReady = existing.tray !== 0 && existing.shell === mainPid && isAlive(existing.tray)
  if (trayReady) {
    log('info', `tray-restart: tray helper ${existing.tray} already running`)
  }
  if (!trayReady && existing.tray !== 0 && isAlive(existing.tray)) {
    // A leftover from the shell that just exited. It would retire on its own timer, but not
    // before this shell asks for its icon, so clear it out first.
    killTree(existing.tray)
    rmSync(PID_FILE, { force: true })
  }

  const lockPath = join(dshHome(), 'profiles', 'desktop', 'lock')
  const args = [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-File',
    LAUNCH_SCRIPT,
    '-MainPid', String(mainPid),
    '-Exe', executable,
    '-Icon', trayIcon,
    '-Lock', lockPath,
    '-LogPath', LOG_FILE,
    '-PidFile', PID_FILE,
  ]

  if (!trayReady) ctx.effect(() => {
    let child
    let spawnLog
    try {
      // Detached children are started with DETACHED_PROCESS on Windows, and Windows
      // PowerShell 5.1 exits immediately without a console. Keep the helper as an ordinary
      // child (orphaned safely if the host dies first) and give it a file for its own errors.
      try {
        spawnLog = openSync(SPAWN_LOG, 'a')
      } catch {
        spawnLog = undefined
      }
      child = spawn('powershell.exe', args, {
        cwd: HERE,
        stdio: ['ignore', spawnLog ?? 'ignore', spawnLog ?? 'ignore'],
        windowsHide: true,
      })
      child.on('error', (error) => log('warn', `tray-restart: could not start tray helper: ${error.message}`))
      child.unref()
      // The launcher only asks WMI to create the icon process and exits; that process records
      // its own pid in PID_FILE once its icon is up.
      log('info', `tray-restart: asked for a tray icon for shell ${mainPid}`)
    } catch (error) {
      log('warn', `tray-restart: spawn failed: ${error?.message ?? error}`)
    } finally {
      if (spawnLog !== undefined) {
        try {
          closeSync(spawnLog)
        } catch {
          /* the child holds its own handle */
        }
      }
    }

    return () => {
      const trayPid = recorded().tray || child?.pid || 0
      if (trayPid !== 0 && isAlive(trayPid)) killTree(trayPid)
      rmSync(PID_FILE, { force: true })
      log('info', 'tray-restart: tray helper stopped')
    }
  })

  // The header button in the Web UI reaches the same operation over one loopback route. The web
  // server can be provided after this plugin, so wait for it rather than probing once at apply.
  ctx.inject(['webServer'], (inner) => {
    const server = inner.webServer
    if (server === undefined || typeof server.register !== 'function') {
      log('warn', 'tray-restart: web server has no route table, the header button stays hidden')
      return
    }
    const route = createRestartRoute({
      mainPid,
      executable,
      lockPath,
      origin: () => server.getOrigin(),
      log,
    })
    inner.effect(() => server.register(route))
    log('info', `tray-restart: restart route listening on ${ROUTE}/restart`)
  })
}
