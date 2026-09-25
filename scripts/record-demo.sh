#!/bin/bash
# Records a real screen demo of Portside showing made-up projects, so nothing private is on camera.
#   scripts/record-demo.sh [seconds]      → build/launch/raw.mov  (default 30 s)
# Your terminal app needs Screen Recording permission; macOS asks the first time.
set -euo pipefail
cd "$(dirname "$0")/.."

secs=${1:-30}
out=build/launch/raw.mov
mkdir -p build/launch
[[ -x build/Portside.app/Contents/MacOS/Portside ]] || ./build.sh >/dev/null

# Swap your everyday Portside for the demo one, and put it back afterwards.
was_running=false
if pgrep -x Portside >/dev/null; then was_running=true; pkill -x Portside; sleep 1; fi
restore() {
    pkill -x Portside 2>/dev/null || true
    if $was_running; then sleep 1; open "$HOME/Applications/Portside.app" 2>/dev/null || open build/Portside.app; fi
}
trap restore EXIT
open build/Portside.app --args --demo

cat <<EOF

Portside is running in demo mode: made-up projects, and Stop only pretends.

Recording your main display for ${secs}s. Hide this terminal (⌘H) during the countdown, then:
  1. Click the Portside icon in the menu bar. Pause a beat.
  2. Slowly move down the list; rest on the "Claude Code" row in the worktree group.
  3. Click its stop button and watch it go.
  4. Click Stop All, then confirm.
  5. Click away to close the menu.

EOF
for i in 5 4 3 2 1; do printf '%s… ' "$i"; sleep 1; done
echo "recording"
screencapture -v -C -V "$secs" "$out"
echo "Saved $out"
