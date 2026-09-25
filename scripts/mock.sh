#!/bin/bash
# Spins up a fake-but-realistic dev environment for trying Portside:
# git repos + a worktree, `npm run dev` chains, a turbo monorepo, agent-launched
# servers and background services. Every "server" is a tiny Node listener named
# after the real tool, so Portside sees exactly what it would see in real life.
#
#   scripts/mock.sh up     start everything
#   scripts/mock.sh down   stop everything and delete the fixtures
set -euo pipefail

ROOT="${TMPDIR:-/tmp}"
ROOT="${ROOT%/}/portside-mock"
BIN="$ROOT/bin"

down() {
    pkill -f "$ROOT" 2>/dev/null || true
    sleep 0.5
    pkill -9 -f "$ROOT" 2>/dev/null || true
    rm -rf "$ROOT"
    echo "Mock environment stopped and removed."
}

up() {
    command -v node >/dev/null || { echo "Needs Node.js"; exit 1; }
    [[ -d "$ROOT" ]] && down >/dev/null
    mkdir -p "$BIN" "$ROOT/logs"

    # One fake server, many names: listens on --port/-p/$PORT (+ $MOCK_EXTRA_PORTS).
    cat > "$BIN/listen" <<'JS'
#!/usr/bin/env node
const http = require('http'), path = require('path');
const name = path.basename(process.argv[1]), args = process.argv.slice(2);
const flag = (...names) => { for (const n of names) { const i = args.indexOf(n); if (i >= 0) return args[i + 1]; } };
const host = flag('--host', '--bind') || '127.0.0.1';
const ports = [flag('--port', '-p') || process.env.PORT, ...(process.env.MOCK_EXTRA_PORTS || '').split(',')]
  .filter(Boolean).map(Number);
for (const port of ports) {
  http.createServer((_, res) => res.end(`mock ${name} on :${port}\n`))
    .listen(port, host).on('error', e => console.error(`${name}: ${e.message}`));
}
JS
    # Fake turbo: runs `npm run dev` in each app, like the real one.
    cat > "$BIN/turbo" <<'JS'
#!/usr/bin/env node
const { spawn } = require('child_process'), path = require('path');
for (const app of ['web', 'api']) spawn('npm', ['run', 'dev'], { cwd: path.join(process.cwd(), 'apps', app), stdio: 'inherit' });
JS
    # Fake agents: stay alive as the parent of whatever they run.
    for agent in claude codex; do printf '#!/bin/bash\n"$@"\n' > "$BIN/$agent"; done
    for tool in next storybook vite tsx uvicorn redis-server postgres mailpit; do ln -s listen "$BIN/$tool"; done
    chmod +x "$BIN"/*

    tools() { mkdir -p "$1/node_modules/.bin"; for t in "${@:2}"; do ln -sf "$BIN/$t" "$1/node_modules/.bin/$t"; done; }
    repo() { git -C "$1" init -q -b main && git -C "$1" add -A &&
             git -C "$1" -c user.name=mock -c user.email=mock@example.com commit -qm init; }
    # Only nohup is backgrounded, so the subshell exits right away instead of
    # lingering (and holding this script's stdout open) until the server dies.
    start() { local log="$ROOT/logs/$1.log"; shift; (cd "$1" || exit; shift; nohup "$@" >"$log" 2>&1 </dev/null &); }

    # acme-web: Next.js + Storybook, plus a worktree on feat/checkout.
    local web="$ROOT/acme-web"
    mkdir -p "$web"
    printf 'node_modules\n' > "$web/.gitignore"
    cat > "$web/package.json" <<'JSON'
{ "name": "acme-web", "scripts": { "dev": "next dev", "storybook": "storybook dev -p 6006" } }
JSON
    repo "$web"
    git -C "$web" worktree add -q -b feat/checkout "$ROOT/acme-web-checkout"
    tools "$web" next storybook
    tools "$ROOT/acme-web-checkout" next storybook

    # acme-mono: turbo running a Vite app (+ HMR port) and a tsx API.
    local mono="$ROOT/acme-mono"
    mkdir -p "$mono/apps/web" "$mono/apps/api"
    printf 'node_modules\n' > "$mono/.gitignore"
    echo '{ "name": "acme-mono", "scripts": { "dev": "turbo run dev" } }' > "$mono/package.json"
    echo '{ "name": "web", "scripts": { "dev": "MOCK_EXTRA_PORTS=24678 vite --port 5173" } }' > "$mono/apps/web/package.json"
    echo '{ "name": "api", "scripts": { "dev": "PORT=4000 tsx watch src/index.ts" } }' > "$mono/apps/api/package.json"
    repo "$mono"
    tools "$mono" turbo
    tools "$mono/apps/web" vite
    tools "$mono/apps/api" tsx

    # acme-api: Python-style API, exposed on all interfaces.
    local api="$ROOT/acme-api"
    mkdir -p "$api/.venv/bin"
    ln -s "$BIN/uvicorn" "$api/.venv/bin/uvicorn"
    printf '.venv\n' > "$api/.gitignore"
    repo "$api"

    start next         "$web"                   env PORT=3000 npm run dev
    start storybook    "$web"                   npm run storybook
    start checkout     "$ROOT/acme-web-checkout" "$BIN/claude" env PORT=3001 npm run dev
    start turbo        "$mono"                  npm run dev
    start uvicorn      "$api"                   "$BIN/codex" "$api/.venv/bin/uvicorn" app.main:app --reload --host 0.0.0.0 --port 8000
    start redis        /                        "$BIN/redis-server" --port 6379
    start postgres     /                        "$BIN/postgres" -D /opt/homebrew/var/postgresql@17 -p 5432
    start mailpit      /                        env MOCK_EXTRA_PORTS=1025 "$BIN/mailpit" --port 8025

    sleep 2
    cat <<EOF
Mock environment running in $ROOT

  acme-web            Next.js :3000, Storybook :6006
  acme-web (worktree) Next.js :3001 on feat/checkout, via Claude Code
  acme-mono           turbo → Vite :5173 + :24678, tsx API :4000
  acme-api            Uvicorn :8000 on all interfaces, via Codex
  Services            Redis :6379, PostgreSQL :5432, Mailpit :8025 + :1025

Open Portside from the menu bar. Stop everything with: scripts/mock.sh down
EOF
    if grep -qh "EADDRINUSE" "$ROOT"/logs/*.log 2>/dev/null; then
        echo; echo "Some ports were already taken:"; grep -h "EADDRINUSE" "$ROOT"/logs/*.log
    fi
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    *) echo "Usage: $0 up|down"; exit 1 ;;
esac
