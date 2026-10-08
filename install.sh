#!/bin/bash
# One-line install: builds the latest Portside release from source and puts it in ~/Applications.
#   curl -fsSL https://raw.githubusercontent.com/guneysol/portside/main/install.sh | bash
#
# What this does: checks for Apple's developer tools, clones the latest release tag into a
# temporary folder, builds it, and copies Portside.app to ~/Applications. No sudo, nothing else
# on your Mac is touched, and the temporary folder is deleted afterwards.
#
# Set PORTSIDE_REF=main (or any tag) to build something other than the latest release.
set -euo pipefail

# Everything lives in main(), which only runs on the last line, so a download that is cut off
# halfway runs nothing at all.
main() {
    local repo=https://github.com/guneysol/portside

    # /usr/bin/swift exists even without the tools (it is an installer stub), so ask xcode-select.
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "Portside builds from source and needs Apple's developer tools."
        echo "Install them with:  xcode-select --install   (then run this again)"
        exit 1
    fi

    local ref="${PORTSIDE_REF:-}"
    if [[ -z "$ref" ]]; then
        ref=$(git ls-remote --tags --refs "$repo" 'v*' | sed 's#.*refs/tags/##' | sort -V | tail -1)
        [[ -n "$ref" ]] || { echo "Couldn't find a Portside release on GitHub."; exit 1; }
    fi
    echo "Installing Portside ${ref}..."

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$repo" "$dir"
    "$dir/build.sh" --install
}

main "$@"
