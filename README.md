# dsh-tray-restart

Restart the DeepSeek Harness desktop app — the Electron shell **and** the Host process it runs — without quitting by hand.

A restart button in the session header, plus a Windows tray icon with the same action. Other plugins, skins, and settings are reloaded on the way up.

> **Windows only.** The plugin lives on WinForms and `taskkill`; on any other platform it does nothing and logs why.

## What you get

- **Header button** — a small restart icon in the top-right utilities row of every session.
- **Tray icon** — right-click for `Restart DSH (app + host)` / `Open DeepSeek Harness` / `Quit tray icon`. Left-click opens the app.
- **One action** — both paths kill the whole process tree (`taskkill /T /F`), wait for it to exit, clear a stale profile lock if the previous run left one, and start the app again.

## Requirements

- DeepSeek Harness desktop app, Windows 10 or 11.
- Nothing else. No build step, no dependencies.

## Install

```sh
# from npm — prebuilt, no build step
dsh plugin add dsh-tray-restart

# or straight from this repository
dsh plugin add https://github.com/Joshua1ya/dsh-tray-restart
```

Then **quit the app completely and reopen it once** — client bundles and the host rows are collected at startup, so a page refresh is not enough.

After that first restart the plugin maintains itself: the header button is there, and the tray icon appears on every launch.

## Uninstall

```sh
dsh plugin remove dsh-tray-restart
```

The tray icon disappears with the next app restart (or quit it from its own menu).

## How it works

| Piece | What it does |
| --- | --- |
| `index.js` (Host) | Registers `GET /dsh-tray-restart/status` and `POST /dsh-tray-restart/restart` on the web server, and starts the tray helper. |
| `client.js` (Web UI) | Renders the header button into `conversation.session.header.utilities`. |
| `assets/tray.ps1` | WinForms `NotifyIcon`, polls the shell process so it disappears when the app does. |
| `assets/launch-*.ps1` | Start the tray or the restart helper through WMI (`Win32_Process.Create`) — see below. |
| `assets/restart.ps1` | Kill the shell (and its process tree), wait, clear `~/.dsh/profiles/<profile>/lock`, relaunch the executable. |

Two implementation details worth knowing if you fork this:

1. **The helper must be started outside the app's process tree.** The Host runs inside a Job object that restricts USER handles, so a child process created with a normal `spawn`/`Start-Process` builds its `NotifyIcon` without error but never appears in the notification area. Processes created through `Win32_Process.Create` are parented to `WmiPrvSE` instead and register fine. The restart helper goes through the same path for the same reason — and it must, because it kills the app's process tree and would otherwise kill itself first.
2. **`ctx.get('webServer')` is `undefined` during a plugin's `apply`.** The web server starts after plugin rows load. Route registration therefore waits with `ctx.inject(['webServer'], …)`; the tray start is independent and must not `return` early.

Restarting from here is equivalent to quitting the app from its menu and launching it again — nothing is kept in memory across the restart.

## License

MIT
