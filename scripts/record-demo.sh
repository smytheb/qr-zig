#!/usr/bin/env sh
# Record the terminal demo GIF (docs/demo.gif) from demo.tape using VHS.
#
#   scripts/record-demo.sh
#
# Requires VHS (https://github.com/charmbracelet/vhs), which itself needs ttyd
# and ffmpeg on PATH. Install with:  go install github.com/charmbracelet/vhs@latest
set -eu

cd "$(dirname "$0")/.."

if ! command -v vhs >/dev/null 2>&1; then
    echo "error: 'vhs' not found on PATH." >&2
    echo "       install: go install github.com/charmbracelet/vhs@latest" >&2
    echo "       (vhs also needs 'ttyd' and 'ffmpeg')" >&2
    exit 1
fi

# Build a small release binary; demo.tape prepends ./zig-out/bin to PATH.
zig build -Doptimize=ReleaseSmall

mkdir -p docs
vhs demo.tape
echo "wrote docs/demo.gif"
