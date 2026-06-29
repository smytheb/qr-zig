# qr

A lightweight, idiomatic, **pure-Zig** command-line QR code **generator and
decoder** — no C libraries, no external runtime dependencies.

> Status: the encoder works end-to-end. It produces spec-correct, scannable QR
> codes with **optimal mixed-mode segmentation** (numeric / alphanumeric / byte),
> **ECI / UTF-8** declaration, **versions 1–40**, all EC levels — verified
> module-for-module against the `qrcode` reference library across every mode,
> version, and mask. A **symbol decoder** (matrix → text, with Reed-Solomon error
> correction) round-trips every generated code; `qr decode` reads the `ascii`,
> `pbm`, and `png` formats (auto-detected). Kanji mode is deferred; a full image
> front-end (binarization, finder detection, perspective) and structured append
> are future directions.

## Scope (v1)

- **Generate, display, and decode.** Encoding is complete; the decoder recovers
  text from a module matrix parsed from our `ascii`, `pbm`, or `png` output — no
  image binarization / finder detection for arbitrary photos yet.
- **Numeric, alphanumeric, and byte/UTF-8 modes** with optimal mixed-mode
  segmentation — the input is split into the cheapest sequence of segments (e.g.
  a digit run inside prose is encoded as its own numeric segment).
- **ECI** support: a UTF-8 declaration (ECI 26) is emitted automatically for
  non-ASCII input (override with `--utf8` / `--eci N` / `--no-eci`).
- Versions 1–40, all four EC levels (L/M/Q/H).
- **Renderers:** terminal (Unicode half-blocks), SVG, PNG, ASCII, Netpbm PBM.
- Target **Zig 0.16.0**.

## Install

Download a prebuilt binary for your platform from the
[Releases](https://github.com/smytheb/qr-zig/releases) page, verify it, and put
it on your `PATH`:

```sh
# pick the asset for your platform, e.g. x86_64-linux-musl
tar -xzf qr-x86_64-linux-musl.tar.gz
sha256sum -c SHA256SUMS                 # optional: verify the checksum
sudo install qr-x86_64-linux-musl/qr /usr/local/bin/
```

The Linux binaries are statically linked (musl), so they have no runtime
dependencies. Or build from source with Zig 0.16.0:

```sh
zig build -Doptimize=ReleaseSafe        # binary at zig-out/bin/qr
```

## Build & run

```sh
zig build                 # build the `qr` binary into zig-out/bin/
zig build run -- help     # run with arguments
zig build test            # run the unit test suite

qr gen "https://ziglang.org"                 # half-block QR in the terminal
echo -n "https://ziglang.org" | qr gen       # read text from stdin
qr gen "hi" --format svg -o code.svg         # write an SVG file
qr gen "hi" --format ascii | qr decode       # encode then decode back to "hi"
qr decode -v code.txt                         # decode a file; -v prints metadata
qr info                                       # capacity table per version/EC
```

**Which format scans?** `terminal` (default) renders square, scannable
half-blocks in any terminal theme; `svg`, `png`, and `pbm` are scannable image
files (`png` is compressed via the standard library's zlib — no third-party deps).
`ascii` is one character per module for piping/debugging — text cells aren't
square, so it is not reliably scannable. `--invert` produces a photo-negative
for dark displays (scanners that support inverted codes, including iOS).

> Zig must be installed (0.16.0). The project pins `minimum_zig_version` in
> `build.zig.zon`. If the first `zig build` reports a `fingerprint` mismatch,
> copy the value it prints into `build.zig.zon`.

## Layout

```
src/
  main.zig            CLI entry: argument dispatch, arena-per-command
  qr/
    root.zig          public API surface
    galois.zig        GF(256) arithmetic (comptime exp/log tables)   
    reed_solomon.zig  RS encode + decode (syndrome/BM/Chien/Forney)  
    bitstream.zig     MSB-first bit writer + reader                  
    segment.zig       optimal mixed-mode segmentation (DP)            
    encode.zig        numeric/alphanumeric/byte + ECI encode/decode  
    tables.zig        v1-40 capacity + block structure               
    matrix.zig        function patterns + zigzag data placement      
    mask.zig          8 masks + penalty scoring                      
    format_info.zig   format/version BCH info                        
    generate.zig      encode -> interleave -> matrix -> mask          
  render/
    ascii.zig         '#'/space matrix                              
    terminal.zig      Unicode half-blocks + ANSI (scannable)        
    svg.zig           vector, run-merged rects                      
    pbm.zig           Netpbm P1 bitmap                              
    png.zig           8-bit grayscale, std zlib-compressed          
  decode/
    reader.zig        matrix -> codewords (reverse zigzag, RS fix)  
    matrix_input.zig  parse ascii/pbm/png rendering into a matrix   
    decode.zig        readFormat -> unmask -> read -> segments       
```

## Verifying output

Encoder correctness is checked against an independent reference encoder used
**only for testing** (not linked, not a runtime dep); the decoder is checked by
round-tripping every generated symbol back to its text (including injected
error correction). The Python
`qrcode` library is a deterministic oracle — the test compares the full module
matrix, which is stronger than a scan:

```sh
qr gen "Hello, World!" --format ascii --quiet 0   # compare module-for-module
python3 -c "import qrcode; ..."                    # vs qrcode.get_matrix()
```

The encoder is verified this way across versions 1–40, all EC levels, and all
eight masks — run it yourself:

```sh
zig build && python3 scripts/oracle_check.py    # needs: pip install qrcode
```

A golden fixture in `zig build test` also locks in a verified matrix so the Zig
suite needs no Python.

## Roadmap

0. Image front-end (binarization / finder
   detection / perspective for arbitrary photos)

## References

- [ISO/IEC 18004:2015](https://www.iso.org/standard/62021.html) — the QR Code
  symbology standard this implementation targets.
- [qrcode.com](https://www.qrcode.com/en/) — DENSO WAVE's official QR Code site
  ([standards index](https://www.qrcode.com/en/about/standards.html)).

## Trademark

"QR Code" is a registered trademark of
[DENSO WAVE INCORPORATED](https://www.denso-wave.com/en/). This is an
independent, unaffiliated implementation of the symbology standardized as
ISO/IEC 18004; it is not endorsed by or associated with DENSO WAVE.