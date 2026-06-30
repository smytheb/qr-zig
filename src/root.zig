//! Public API for the `qr` library: **encode**, **render**, and **decode** QR
//! codes in pure Zig with no external dependencies.
//!
//! This is the module published by `build.zig` (`b.addModule("qr", ...)`). It
//! is consumed both by the official CLI (`src/main.zig`) and by downstream
//! projects via `@import("qr")`:
//!
//! ```zig
//! const qr = @import("qr");
//! var code = try qr.generate(allocator, "https://ziglang.org", .m, .auto);
//! defer code.deinit();
//! try qr.render.svg.render(writer, &code.matrix, .{});
//! ```

// ---- Encoder ---------------------------------------------------------------
// The encoder lives under `src/qr/`; re-export its full surface (entry points,
// types, and low-level submodules) from here. See `src/qr/root.zig`.
const enc = @import("qr/root.zig");

pub const galois = enc.galois;
pub const reed_solomon = enc.reed_solomon;
pub const tables = enc.tables;
pub const bitstream = enc.bitstream;
pub const segment = enc.segment;
pub const encode = enc.encode;
pub const matrix = enc.matrix;
pub const mask = enc.mask;
pub const format_info = enc.format_info;
pub const generate_mod = enc.generate_mod;

/// Error-correction level (L/M/Q/H).
pub const EcLevel = enc.EcLevel;
/// A QR module matrix.
pub const Matrix = enc.Matrix;
/// Result of `generate`: a masked matrix plus its version/level/mask metadata.
pub const Generated = enc.Generated;
/// Extended Channel Interpretation policy (UTF-8 declaration).
pub const Eci = enc.Eci;

/// Full pipeline: text -> masked QR matrix with format/version info.
pub const generate = enc.generate;
/// Same, but with an explicit mask (deterministic; for testing).
pub const generateWithMask = enc.generateWithMask;
/// Unmasked matrix without format/version info (for testing placement).
pub const generateUnmasked = enc.generateUnmasked;

// ---- Renderers -------------------------------------------------------------
/// Output renderers; each exposes `render(writer, &matrix, .{ ... })`.
pub const render = struct {
    pub const ascii = @import("render/ascii.zig");
    pub const terminal = @import("render/terminal.zig");
    pub const svg = @import("render/svg.zig");
    pub const pbm = @import("render/pbm.zig");
    pub const png = @import("render/png.zig");
};

// ---- Decoder ---------------------------------------------------------------
/// Symbol decoder: `decodeMatrix(allocator, &matrix)` -> `decode.Decoded`.
pub const decode = @import("decode/decode.zig");
/// Parse a rendered symbol (ascii/pbm/png) back into a `Matrix`.
pub const matrix_input = @import("decode/matrix_input.zig");

test {
    _ = enc; // pulls the entire encoder test graph (see src/qr/root.zig)
    _ = render.ascii;
    _ = render.terminal;
    _ = render.svg;
    _ = render.pbm;
    _ = render.png;
    _ = decode;
    _ = matrix_input;
}
