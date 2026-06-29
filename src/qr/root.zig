//! Public API surface for the `qr` encoder library.

pub const galois = @import("galois.zig");
pub const reed_solomon = @import("reed_solomon.zig");
pub const tables = @import("tables.zig");
pub const bitstream = @import("bitstream.zig");
pub const segment = @import("segment.zig");
pub const encode = @import("encode.zig");
pub const matrix = @import("matrix.zig");
pub const mask = @import("mask.zig");
pub const format_info = @import("format_info.zig");
pub const generate_mod = @import("generate.zig");

/// Error-correction level (re-exported from the spec tables).
pub const EcLevel = tables.EcLevel;
pub const Matrix = matrix.Matrix;
pub const Generated = generate_mod.Generated;
/// Extended Channel Interpretation policy (UTF-8 declaration).
pub const Eci = encode.Eci;

/// Full pipeline: text -> masked QR matrix with format/version info.
pub const generate = generate_mod.generate;
/// Same, but with an explicit mask (deterministic; for testing).
pub const generateWithMask = generate_mod.generateWithMask;
/// Unmasked matrix without format/version info (for testing placement).
pub const generateUnmasked = generate_mod.generateUnmasked;

test {
    _ = galois;
    _ = reed_solomon;
    _ = tables;
    _ = bitstream;
    _ = segment;
    _ = encode;
    _ = matrix;
    _ = mask;
    _ = format_info;
    _ = generate_mod;
}
