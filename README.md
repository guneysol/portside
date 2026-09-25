# Portside

A tiny macOS menu bar app that shows every dev server and local service
listening on your machine, grouped by project and git worktree, with one-click stop.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img src="docs/screenshot-light.png" width="360" alt="Portside menu showing dev servers grouped by project">
</picture>

- **Finds everything listening on TCP**, including Next.js, Vite, Uvicorn, Rails, Postgres,
  Redis, Docker, Ollama and about 80 more, recognized by name.
- **Groups by project**, and tells git worktrees apart by branch.
- **Shows who started it**: Claude Code, Codex, Cursor, your terminal or `brew services`.
- **Stops it properly.** It takes down the whole `npm → sh → node` chain without touching
  sibling servers, and stops brew services through `brew services stop` so they don't respawn.
- Click a port to open it in the browser, or to copy the address for databases and services.
  Ports reachable from your network are marked. Right-click a row for Reveal in Finder,
  Copy Command and Force Quit.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/guneysol/portside/main/install.sh | bash
```

This builds from source (about 30 s) and installs to `~/Applications`. You need macOS 14+
and Apple's developer tools (`xcode-select --install`). Because it's built on your machine,
Gatekeeper won't block it.

Or clone the repo and run:

```bash
./build.sh --install
```

Turn on **Launch at Login** from the `⋯` menu.

## Lightweight by design

Portside reads everything directly from the kernel (`sysctl` for the process table, `libproc`
for sockets and working directories), so it never spawns `lsof` or `ps`.

| | |
|---|---|
| One scan | ~1 ms |
| Idle CPU | ~0.1% of one core |
| Memory | ~17 MB |
| Network | none, nothing leaves your Mac |

It scans every 2 s while the menu is open and every 10 s in the background, just to keep the
menu bar count current. Background timers let macOS batch wakeups to save energy.

**Coverage:** every TCP listener owned by your user, which covers everything you can stop.
Listeners owned by root, which no unprivileged tool can see through `libproc`, are filled in
from `netstat` while the menu is open. System daemons and GUI apps (AirPlay, Spotify…) are
hidden by default. Turn on **Show System & App Listeners** to see them.

## Development

```bash
./build.sh --open                           # build and relaunch
build/Portside.app/Contents/MacOS/Portside --list    # print what it sees
build/Portside.app/Contents/MacOS/Portside --bench   # time a scan
```

The code is plain SwiftUI plus Swift Package Manager, with no dependencies:

- `Scanner.swift` handles kernel reads, the process tree and project detection.
- `Classifier.swift` handles friendly names.
- `Store.swift` handles polling and stopping.
- `Views.swift` is the UI.

## License

MIT
