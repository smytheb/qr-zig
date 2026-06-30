# demo.tape — terminal demo for the README, recorded with VHS.
#
#   scripts/record-demo.sh        # builds qr, then runs `vhs demo.tape`
#   # or, if `qr` is already on PATH:  vhs demo.tape
#
# VHS: https://github.com/charmbracelet/vhs  (needs ttyd + ffmpeg)

Output docs/demo.gif

Set Shell bash
Set FontSize 16
Set Width 1200
Set Height 820
Set Padding 24
Set Theme "Catppuccin Mocha"

# Use the freshly built binary without showing the PATH plumbing.
Hide
Type "export PATH=$PWD/zig-out/bin:$PATH && clear" Enter
Show

Sleep 700ms

# 1. Generate a scannable code right in the terminal.
Type "qr gen 'https://ziglang.org'" Sleep 600ms Enter
Sleep 2.5s

# 2. Photo-negative variant for dark terminals.
Type "qr gen 'Zig ⚡' --invert" Sleep 600ms Enter
Sleep 2.5s

# 3. Round-trip: encode to ASCII, pipe straight back into the decoder.
Type "qr gen 'ziglang' --format ascii | qr decode" Sleep 600ms Enter
Sleep 2.5s
