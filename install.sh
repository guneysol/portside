#!/bin/bash
# One-line install: builds Portside from source and puts it in ~/Applications.
#   curl -fsSL https://raw.githubusercontent.com/guneysol/portside/main/install.sh | bash
set -euo pipefail

# /usr/bin/swift exists even without the tools (it is an installer stub), so ask xcode-select.
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Portside builds from source and needs Apple's developer tools."
    echo "Install them with:  xcode-select --install   — then run this again."
    exit 1
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
git clone --quiet --depth 1 https://github.com/guneysol/portside "$dir"
"$dir/build.sh" --install
