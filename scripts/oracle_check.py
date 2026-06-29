#!/usr/bin/env python3
"""Validation harness: compare `qr`'s output against the `qrcode` reference
library module-for-module, across a sweep of versions, EC levels, and all eight
mask patterns.

Encoder correctness is checked against an independent encoder (the deterministic
`qrcode` library) module-for-module — stronger than a scan. The decoder is
checked the other way: `qrcode` *encodes*, and `qr decode` reads its rendered
matrix back to text, proving interoperability rather than mere self-consistency.

Requirements:
    pip install qrcode
    zig build           # so zig-out/bin/qr exists

Usage:
    python3 scripts/oracle_check.py [path/to/qr]

Exits 0 if everything matches, 1 otherwise.

Note: cases span numeric / alphanumeric / byte / mixed / non-ASCII inputs. PNG
output is additionally decoded and compared module-for-module, and `qr decode` is
exercised against qrcode-encoded symbols. A forced mask is passed to both sides
of the encoder comparison so it is deterministic.
"""

import struct
import subprocess
import sys
import zlib

try:
    import qrcode
    from qrcode.util import QRData, MODE_NUMBER, MODE_ALPHA_NUM, MODE_8BIT_BYTE
except ImportError:
    sys.exit("error: this harness needs the `qrcode` library (pip install qrcode)")

EC = {
    "L": qrcode.constants.ERROR_CORRECT_L,
    "M": qrcode.constants.ERROR_CORRECT_M,
    "Q": qrcode.constants.ERROR_CORRECT_Q,
    "H": qrcode.constants.ERROR_CORRECT_H,
}

MODES = {"numeric": MODE_NUMBER, "alphanumeric": MODE_ALPHA_NUM, "byte": MODE_8BIT_BYTE}

PHRASE = "the quick brown fox jumps over 13 lazy dogs; "  # forces byte mode

# Byte-mode cases: (byte length, EC level), spanning low to high versions.
BYTE_CASES = [
    (13, "M"), (13, "Q"), (13, "H"), (44, "M"), (120, "L"),
    (300, "M"), (700, "Q"), (1200, "H"), (2000, "L"), (2900, "L"),  # ~v40
]

# Literal cases exercising numeric and alphanumeric modes: (text, EC level).
TEXT_CASES = [
    ("0123456789012345", "M"),               # numeric
    ("8675309" * 30, "Q"),                   # numeric, higher version
    ("HELLO WORLD", "M"),                    # alphanumeric
    ("HTTPS://EXAMPLE.COM/PATH-42 $%", "L"),  # alphanumeric, full charset
    ("HELLO WORLD " * 40, "H"),              # alphanumeric, higher version
]

# Mixed-mode cases: the reference is built from `qr`'s own optimal segmentation
# (reported by `qr segments`) so the comparison checks the multi-segment
# encoding rather than which library segments how.
MIXED_CASES = [
    ("Visit HTTP://A.COM or call 18005551234 now", "M"),
    ("ORDER #12345 for user@site (qty 7)", "Q"),
    ("ABC123def456GHI", "L"),
    ("2026-06-29T12:00 Meeting Room A12", "H"),
]

# Non-ASCII byte payloads (raw UTF-8), checked with --no-eci against qrcode's
# byte mode. These avoid digit / uppercase-ASCII runs so the optimal split is a
# single byte segment (otherwise `qr` would correctly extract numeric/alpha
# segments and diverge from an all-byte reference). The ECI header itself is
# covered by Zig unit/golden tests, since qrcode has no ECI support.
NONASCII_CASES = [
    ("café — 日本語 — €".encode(), "M"),
    ("smörgåsbord ½ ¾ — ñoño — ©®".encode(), "Q"),
]

# PNG cases: decode `qr`'s PNG output (stdlib zlib/struct, no Pillow needed) and
# compare the module grid to the reference. Rendered at --scale 1 --quiet 0 so
# one pixel == one module; spans byte and alphanumeric inputs / low-high version.
PNG_CASES = [
    ("the quick brown fox", "M"),
    ("HELLO WORLD 42", "Q"),
    (PHRASE * 6, "H"),  # ~270 bytes -> higher version
]

# Decode cases: encode with the qrcode *reference* library, render its matrix to
# ascii, and feed it to `qr decode`. This checks our decoder against an
# independent encoder (interoperability) rather than only round-tripping our own
# output. Mask choice is irrelevant — the decoder reads it from the format info —
# so qrcode's non-spec auto mask is fine here. ASCII payloads only (qrcode has no
# ECI; for ASCII the decoded bytes equal the input exactly).
DECODE_CASES = [
    ("0123456789", "L"),  # numeric
    ("HELLO WORLD", "M"),  # alphanumeric
    ("Hello, World!", "Q"),  # byte
    ("https://ziglang.org/learn", "H"),  # byte, higher version
    ("the quick brown fox jumps over 13 lazy dogs", "L"),  # mixed-ish, multi-segment
    (PHRASE * 4, "M"),  # ~180 bytes, multi-block
]


def mine(qr_bin, text, ec, mask):
    out = subprocess.run(
        [qr_bin, "gen", text, "--ec", ec, "--mask", str(mask),
         "--quiet", "0", "--format", "ascii"],
        capture_output=True, text=True, check=True).stdout
    return [[1 if c == "#" else 0 for c in row] for row in out.split("\n") if row]


def ref(text, ec, mask, version):
    q = qrcode.QRCode(version=version, error_correction=EC[ec],
                      mask_pattern=mask, border=0)
    # optimize=0 forces a single auto-detected segment (numeric/alphanumeric/
    # byte), matching `qr`'s whole-string mode selection.
    q.add_data(text, optimize=0)
    q.make(fit=False)
    return [[1 if v else 0 for v in row] for row in q.get_matrix()]


def check(qr_bin, text, ec, label):
    first = mine(qr_bin, text, ec, 0)
    version = (len(first) - 17) // 4
    ok = all(mine(qr_bin, text, ec, m) == ref(text, ec, m, version)
             for m in range(8))
    print(f"{label:11s} ec={ec} -> v{version:2d} "
          f"({len(first)}x{len(first)}) all 8 masks: {'MATCH' if ok else 'FAIL'}")
    return ok


def segments(qr_bin, text, ec):
    out = subprocess.run([qr_bin, "segments", text, "--ec", ec],
                         capture_output=True, text=True, check=True).stdout.splitlines()
    version = int(out[0].split()[1])
    segs = [(p[0], int(p[1]), int(p[2])) for p in (line.split() for line in out[1:])]
    return version, segs


def ref_mixed(text, ec, mask, version, segs):
    q = qrcode.QRCode(version=version, error_correction=EC[ec], mask_pattern=mask, border=0)
    raw = text.encode()
    for mode, start, length in segs:
        q.add_data(QRData(raw[start:start + length], mode=MODES[mode]))
    q.make(fit=False)
    return [[1 if v else 0 for v in row] for row in q.get_matrix()]


def check_mixed(qr_bin, text, ec):
    version, segs = segments(qr_bin, text, ec)
    ok = all(mine(qr_bin, text, ec, m) == ref_mixed(text, ec, m, version, segs)
             for m in range(8))
    print(f"mixed/{len(segs)}seg  ec={ec} -> v{version:2d} "
          f"all 8 masks: {'MATCH' if ok else 'FAIL'}  {text[:30]!r}")
    return ok


def check_nonascii(qr_bin, raw, ec):
    """Raw byte payload compared with --no-eci against qrcode byte mode."""
    def mine_bytes(mask):
        out = subprocess.run([qr_bin.encode(), b"gen", raw, b"--ec", ec.encode(),
                              b"--mask", str(mask).encode(), b"--quiet", b"0",
                              b"--format", b"ascii", b"--no-eci"],
                             capture_output=True, check=True).stdout.decode()
        return [[1 if c == "#" else 0 for c in r] for r in out.split("\n") if r]

    first = mine_bytes(0)
    version = (len(first) - 17) // 4
    ok = True
    for mask in range(8):
        q = qrcode.QRCode(version=version, error_correction=EC[ec], mask_pattern=mask, border=0)
        q.add_data(QRData(raw, mode=MODE_8BIT_BYTE))
        q.make(fit=False)
        ref = [[1 if v else 0 for v in row] for row in q.get_matrix()]
        ok = ok and mine_bytes(mask) == ref
    print(f"non-ascii   ec={ec} -> v{version:2d} (--no-eci) all 8 masks: "
          f"{'MATCH' if ok else 'FAIL'}  {len(raw)} bytes")
    return ok


def decode_png_gray(data):
    """Minimal decoder for the exact PNGs `qr` emits: 8-bit grayscale, color
    type 0, filter None, non-interlaced. Returns a 2D list of sample bytes."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "bad PNG signature"
    off, idat, width, height = 8, b"", None, None
    while off < len(data):
        (length,) = struct.unpack(">I", data[off:off + 4])
        ctype = data[off + 4:off + 8]
        cdata = data[off + 8:off + 8 + length]
        off += 12 + length  # length(4) + type(4) + data + crc(4)
        if ctype == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", cdata[:10])
            assert depth == 8 and color == 0, "expected 8-bit grayscale"
        elif ctype == b"IDAT":
            idat += cdata
        elif ctype == b"IEND":
            break
    raw = zlib.decompress(idat)
    stride = 1 + width
    rows = []
    for y in range(height):
        assert raw[y * stride] == 0, "expected filter type 0 (None)"
        rows.append(list(raw[y * stride + 1:y * stride + 1 + width]))
    return rows


def mine_png(qr_bin, text, ec, mask):
    out = subprocess.run(
        [qr_bin, "gen", text, "--ec", ec, "--mask", str(mask),
         "--quiet", "0", "--scale", "1", "--format", "png"],
        capture_output=True, check=True).stdout
    return [[1 if s == 0 else 0 for s in row] for row in decode_png_gray(out)]


def check_png(qr_bin, text, ec):
    first = mine_png(qr_bin, text, ec, 0)
    version = (len(first) - 17) // 4
    ok = all(mine_png(qr_bin, text, ec, m) == ref(text, ec, m, version)
             for m in range(8))
    print(f"png         ec={ec} -> v{version:2d} "
          f"({len(first)}x{len(first)}) all 8 masks: {'MATCH' if ok else 'FAIL'}")
    return ok


def check_decode(qr_bin, text, ec):
    """Encode with the qrcode reference library, render its matrix to ascii, and
    decode it with `qr decode`; the recovered text must match the input."""
    q = qrcode.QRCode(error_correction=EC[ec], border=0)
    q.add_data(text, optimize=0)
    q.make()  # auto version + auto mask
    matrix = q.get_matrix()
    art = "\n".join("".join("#" if cell else " " for cell in row) for row in matrix)

    decoded = subprocess.run([qr_bin, "decode"], input=art,
                             capture_output=True, text=True, check=True).stdout.rstrip("\n")
    ok = decoded == text
    version = (len(matrix) - 17) // 4
    print(f"decode      ec={ec} -> v{version:2d} {'MATCH' if ok else 'FAIL'}  {text[:28]!r}")
    return ok


def main():
    qr_bin = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/qr"
    all_ok = True
    for length, ec in BYTE_CASES:
        text = (PHRASE * (length // len(PHRASE) + 1))[:length]
        all_ok &= check(qr_bin, text, ec, f"byte/{length}")
    for text, ec in TEXT_CASES:
        all_ok &= check(qr_bin, text, ec, "text")
    for text, ec in MIXED_CASES:
        all_ok &= check_mixed(qr_bin, text, ec)
    for raw, ec in NONASCII_CASES:
        all_ok &= check_nonascii(qr_bin, raw, ec)
    for text, ec in PNG_CASES:
        all_ok &= check_png(qr_bin, text, ec)
    for text, ec in DECODE_CASES:
        all_ok &= check_decode(qr_bin, text, ec)
    print("RESULT:", "all cases match the qrcode oracle" if all_ok else "FAILURES")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
