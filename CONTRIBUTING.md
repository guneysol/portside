# Contributing

Thanks for helping! Portside is small on purpose: plain SwiftUI with Swift Package Manager, no
dependencies, and about 1,300 lines.

## Development loop

```bash
git clone https://github.com/guneysol/portside && cd portside
./build.sh --open      # build build/Portside.app and relaunch it
```

You need macOS 14 or later and Xcode 16 (or its Command Line Tools). The build must stay free of
warnings.

### A realistic fake environment

`scripts/mock.sh up` starts a realistic fake dev setup:

- git repos, one with a worktree
- `npm run dev` chains
- a turbo monorepo
- servers "started by" Claude Code and Codex
- Redis, Postgres and Mailpit look-alikes

Every fake server is a tiny Node listener named after the real tool, so Portside can't tell it
apart from the real thing. Run `scripts/mock.sh down` to stop and remove it all.

### Debug flags

```bash
P=build/Portside.app/Contents/MacOS/Portside
$P --list                                  # print what the scanner sees, including root-owned listeners
$P --bench                                 # time a scan
$P --stop <pid>                            # stop one process exactly as the UI does
$P --snapshot out.png --demo [--dark]      # render the menu with fake data (use for screenshots)
```

Never put real `--list` output or live screenshots in issues or PRs without checking them first.
They include your project paths and branch names. `--demo` exists so you don't have to.

## Where things live

| File | What it does |
|---|---|
| `Sources/Portside/Scanner.swift` | Reads processes and sockets from the kernel, walks the process tree to decide what Stop takes down, and detects projects and worktrees |
| `Sources/Portside/Classifier.swift` | Friendly names: **add a tool here** |
| `Sources/Portside/Store.swift` | Polling, refresh and stopping |
| `Sources/Portside/Views.swift` | The menu UI |
| `Sources/Portside/PortsideApp.swift` | App entry point, debug flags, demo data |
| `scripts/make-icon.swift` | Draws the app icon: `swift scripts/make-icon.swift` |

## Ground rules

- **Idle cost is a feature.** No timers, animations or polling that run while the menu is closed,
  beyond the existing 10-second scan. Measure changes to the scan path with `--bench`.
- **Stop must never hit the wrong process.** Changes to the tree-climbing rules need a test
  against `scripts/mock.sh`. Stopping one server must leave its siblings running.
- **Keep it native and dependency-free.**

## Pull requests

1. `./build.sh` passes with no warnings.
2. `--list` still matches `netstat -anv -p tcp` for listeners.
3. If the UI changed, regenerate the README screenshots with
   `--snapshot docs/screenshot-light.png --demo` and `--dark`.
