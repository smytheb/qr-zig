//! Symbol decoder: a QR module matrix back to its text. This is pure
//! orchestration — every step is the inverse of a generator stage and lives in
//! its own module:
//!
//!   readFormat            -> error-correction level + mask
//!   mask.applyMask        -> un-mask the data modules (self-inverse)
//!   readCodewords         -> interleaved codeword stream
//!   deinterleaveAndCorrect-> Reed-Solomon-corrected data codewords
//!   decodeSegments        -> the original text (+ any ECI)
//!
//! The matrix must carry the function-pattern / reserved layout for its version
//! (as produced by `matrix.build` or any generator entry point). Decoding from a
//! raw image grid is the job of a separate input stage.

const std = @import("std");
const tables = @import("../qr/tables.zig");
const matrix = @import("../qr/matrix.zig");
const mask = @import("../qr/mask.zig");
const format_info = @import("../qr/format_info.zig");
const encode = @import("../qr/encode.zig");
const reader = @import("reader.zig");

const Matrix = matrix.Matrix;

pub const Error = format_info.ReadError || reader.Error || encode.DecodeError;

pub const Decoded = struct {
    /// Owned by the caller's allocator.
    text: []u8,
    version: u8,
    level: tables.EcLevel,
    mask: u3,
    eci: ?u32,
};

/// Decode a QR symbol from its module matrix. The matrix is **un-masked in
/// place** (mutated). Caller owns `Decoded.text`.
pub fn decodeMatrix(allocator: std.mem.Allocator, m: *Matrix) Error!Decoded {
    // The version comes from the matrix size (set when the matrix was built),
    // which is unambiguous for clean input; we deliberately don't read or
    // cross-check the v7+ version-information BCH bits.
    const fmt = try format_info.readFormat(m);
    mask.applyMask(m, fmt.mask); // un-mask: applyMask is its own inverse

    const interleaved = try reader.readCodewords(allocator, m);
    defer allocator.free(interleaved);

    const data = try reader.deinterleaveAndCorrect(allocator, interleaved, m.version, fmt.level);
    defer allocator.free(data);

    const seg = try encode.decodeSegments(allocator, data, m.version);
    return .{
        .text = seg.text,
        .version = m.version,
        .level = fmt.level,
        .mask = fmt.mask,
        .eci = seg.eci,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const generate = @import("../qr/generate.zig");

test {
    // Pull reader.zig's tests into the graph alongside this module's.
    _ = reader;
}

test "round-trips generate -> decodeMatrix across modes, levels, and masks" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "12345",
        "HELLO WORLD",
        "Hello, World!",
        "ABC123def456GHI",
        "https://ziglang.org",
    };
    const levels = [_]tables.EcLevel{ .l, .m, .q, .h };
    for (cases) |text| {
        for (levels) |level| {
            var msk: u3 = 0;
            while (true) : (msk += 1) {
                var g = try generate.generateWithMask(a, text, level, msk, .none);
                defer g.deinit();
                const dec = try decodeMatrix(a, &g.matrix);
                defer a.free(dec.text);
                try std.testing.expectEqualStrings(text, dec.text);
                try std.testing.expectEqual(level, dec.level);
                try std.testing.expectEqual(msk, dec.mask);
                try std.testing.expectEqual(g.version, dec.version);
                if (msk == 7) break;
            }
        }
    }
}

test "round-trips the auto-mask pipeline and recovers ECI" {
    const a = std.testing.allocator;
    var g = try generate.generate(a, "café — 日本語", .q, .auto);
    defer g.deinit();
    const dec = try decodeMatrix(a, &g.matrix);
    defer a.free(dec.text);
    try std.testing.expectEqualStrings("café — 日本語", dec.text);
    try std.testing.expectEqual(g.mask, dec.mask);
    try std.testing.expectEqual(@as(?u32, 26), dec.eci); // auto UTF-8 ECI
}

test "round-trips a higher-version multi-block symbol" {
    const a = std.testing.allocator;
    const text = "x" ** 600 ++ " order 12345 ABCDEF";
    var g = try generate.generate(a, text, .m, .none);
    defer g.deinit();
    try std.testing.expect(g.version >= 14);
    const dec = try decodeMatrix(a, &g.matrix);
    defer a.free(dec.text);
    try std.testing.expectEqualStrings(text, dec.text);
}

test "decodeMatrix corrects module errors within capacity" {
    const a = std.testing.allocator;
    // v1-M: single block, ec = 10 -> corrects up to 5 codeword errors.
    var g = try generate.generateWithMask(a, "HELLO WORLD", .m, 3, .none);
    defer g.deinit();

    // Flip 4 spread-out data (non-reserved) modules — at most 4 codeword errors.
    var flipped: usize = 0;
    var y: usize = 0;
    outer: while (y < g.matrix.size) : (y += 1) {
        var x: usize = 0;
        while (x < g.matrix.size) : (x += 1) {
            if (!g.matrix.isReserved(x, y) and (x + y) % 9 == 0) {
                g.matrix.flip(x, y);
                flipped += 1;
                if (flipped == 4) break :outer;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 4), flipped);

    const dec = try decodeMatrix(a, &g.matrix);
    defer a.free(dec.text);
    try std.testing.expectEqualStrings("HELLO WORLD", dec.text);
}
