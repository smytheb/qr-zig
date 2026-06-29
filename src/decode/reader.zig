//! Codeword reading — the inverse of the matrix-placement and interleaving
//! stages. Two steps:
//!
//!   1. `readCodewords`: walk the standard zigzag (identical to
//!      `matrix.placeData`) over an *unmasked* matrix, reading each non-reserved
//!      module back into the interleaved codeword stream.
//!   2. `deinterleaveAndCorrect`: split that stream back into per-block
//!      `data ++ ec`, run Reed-Solomon correction on each block, and return the
//!      concatenated (corrected) data codewords.
//!
//! The caller must un-mask the matrix first (mask application is its own
//! inverse — see `mask.applyMask`). Format/version decoding lives elsewhere.

const std = @import("std");
const tables = @import("../qr/tables.zig");
const reed_solomon = @import("../qr/reed_solomon.zig");
const Matrix = @import("../qr/matrix.zig").Matrix;

pub const Error = error{Uncorrectable} || std.mem.Allocator.Error;

/// Data codewords per block `b` for a given block structure.
fn blockDataLen(s: tables.BlockStructure, b: usize) usize {
    return if (b < s.g1_blocks) s.g1_data else s.g2_data;
}

/// Read the interleaved codeword stream from an *unmasked* matrix by walking the
/// same upward/downward two-column zigzag that `matrix.placeData` writes. The
/// returned slice has length `total_codewords[version]`; trailing remainder bits
/// (which are always zero) are discarded. Caller owns the slice.
pub fn readCodewords(allocator: std.mem.Allocator, m: *const Matrix) Error![]u8 {
    const total = tables.total_codewords[m.version - 1];
    const out = try allocator.alloc(u8, total);
    @memset(out, 0);
    const total_bits = @as(usize, total) * 8;

    var bit: usize = 0;
    var upward = true;
    var col: isize = @intCast(m.size - 1);
    while (col > 0) : (col -= 2) {
        if (col == 6) col -= 1; // skip the vertical timing column
        var k: usize = 0;
        while (k < m.size) : (k += 1) {
            const row = if (upward) m.size - 1 - k else k;
            var pair: usize = 0;
            while (pair < 2) : (pair += 1) {
                const x: usize = @intCast(col - @as(isize, @intCast(pair)));
                if (m.isReserved(x, row)) continue;
                if (bit < total_bits) {
                    if (m.get(x, row)) {
                        const shift: u3 = @intCast(7 - (bit % 8));
                        out[bit / 8] |= @as(u8, 1) << shift;
                    }
                    bit += 1;
                }
            }
        }
        upward = !upward;
    }
    return out;
}

/// Reverse `reed_solomon.interleaveCodewords`: split the interleaved stream into
/// per-block `data ++ ec`, Reed-Solomon-correct each block, and return the
/// concatenated corrected data codewords (block order, length
/// `dataCodewords()`). Errors with `Uncorrectable` if any block exceeds its
/// correction capacity. Caller owns the returned slice.
pub fn deinterleaveAndCorrect(
    allocator: std.mem.Allocator,
    interleaved: []const u8,
    version: u8,
    level: tables.EcLevel,
) Error![]u8 {
    const s = tables.blockStructure(version, level);
    const num_blocks = s.totalBlocks();
    const ec_count: usize = s.ec_per_block;
    const total_data = s.dataCodewords();
    std.debug.assert(interleaved.len == total_data + num_blocks * ec_count);

    const data = try allocator.alloc(u8, total_data); // block-by-block data layout
    errdefer allocator.free(data);
    const ec = try allocator.alloc(u8, num_blocks * ec_count); // block b ec at [b*ec_count..]
    defer allocator.free(ec);

    var pos: usize = 0;

    // De-interleave the data region (column-major across blocks).
    const max_data = @max(s.g1_data, s.g2_data);
    var col: usize = 0;
    while (col < max_data) : (col += 1) {
        var off: usize = 0;
        var b: usize = 0;
        while (b < num_blocks) : (b += 1) {
            const dlen = blockDataLen(s, b);
            if (col < dlen) {
                data[off + col] = interleaved[pos];
                pos += 1;
            }
            off += dlen;
        }
    }

    // De-interleave the EC region (every block has the same EC count).
    var ec_col: usize = 0;
    while (ec_col < ec_count) : (ec_col += 1) {
        var b: usize = 0;
        while (b < num_blocks) : (b += 1) {
            ec[b * ec_count + ec_col] = interleaved[pos];
            pos += 1;
        }
    }
    std.debug.assert(pos == interleaved.len);

    // Correct each block in place and copy its corrected data back.
    var blk: [256]u8 = undefined;
    var off: usize = 0;
    var b: usize = 0;
    while (b < num_blocks) : (b += 1) {
        const dlen = blockDataLen(s, b);
        @memcpy(blk[0..dlen], data[off .. off + dlen]);
        @memcpy(blk[dlen .. dlen + ec_count], ec[b * ec_count ..][0..ec_count]);
        _ = try reed_solomon.decodeBlock(blk[0 .. dlen + ec_count], ec_count);
        @memcpy(data[off .. off + dlen], blk[0..dlen]);
        off += dlen;
    }

    return data;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const encode = @import("../qr/encode.zig");
const generate = @import("../qr/generate.zig");

/// Independently recompute the interleaved codeword stream for `text`.
fn referenceInterleaved(a: std.mem.Allocator, text: []const u8, level: tables.EcLevel) !struct {
    version: u8,
    data: []u8,
    interleaved: []u8,
} {
    const enc = try encode.encode(a, text, level, .auto);
    const inter = try reed_solomon.interleaveCodewords(a, enc.data_codewords, enc.version, level);
    return .{ .version = enc.version, .data = enc.data_codewords, .interleaved = inter };
}

test "readCodewords recovers the interleaved stream from an unmasked matrix" {
    const a = std.testing.allocator;
    const cases = [_]struct { text: []const u8, level: tables.EcLevel }{
        .{ .text = "HELLO WORLD", .level = .m },
        .{ .text = "Hello, World!", .level = .q },
        .{ .text = "the quick brown fox jumps over 13 lazy dogs", .level = .h },
        .{ .text = "x" ** 800, .level = .l }, // multi-block, higher version
    };
    inline for (cases) |c| {
        const ref = try referenceInterleaved(a, c.text, c.level);
        defer a.free(ref.data);
        defer a.free(ref.interleaved);

        var m = try generate.generateUnmasked(a, c.text, c.level, .auto);
        defer m.deinit();

        const got = try readCodewords(a, &m);
        defer a.free(got);
        try std.testing.expectEqualSlices(u8, ref.interleaved, got);
    }
}

test "deinterleaveAndCorrect inverts interleaving on a clean stream" {
    const a = std.testing.allocator;
    const cases = [_]struct { text: []const u8, level: tables.EcLevel }{
        .{ .text = "HELLO WORLD", .level = .m },
        .{ .text = "x" ** 300, .level = .q }, // two block groups
    };
    inline for (cases) |c| {
        const ref = try referenceInterleaved(a, c.text, c.level);
        defer a.free(ref.data);
        defer a.free(ref.interleaved);

        const recovered = try deinterleaveAndCorrect(a, ref.interleaved, ref.version, c.level);
        defer a.free(recovered);
        try std.testing.expectEqualSlices(u8, ref.data, recovered);
    }
}

test "deinterleaveAndCorrect repairs errors routed across multiple blocks" {
    const a = std.testing.allocator;
    const text = "x" ** 21; // 21 bytes -> v3-H: 2 blocks of 13 data, ec 22 (t = 11)
    const level: tables.EcLevel = .h;

    const ref = try referenceInterleaved(a, text, level);
    defer a.free(ref.data);
    defer a.free(ref.interleaved);

    const s = tables.blockStructure(ref.version, level);
    try std.testing.expectEqual(@as(u8, 3), ref.version);
    try std.testing.expectEqual(@as(usize, 2), s.totalBlocks());

    // The data region is interleaved column-wise across blocks, so the first
    // `num_blocks * t` codewords are exactly the first `t` columns of every block
    // — `t` errors per block, right at the correction limit (t = 11 <= 13 data).
    const t = s.ec_per_block / 2;
    for (0..s.totalBlocks() * t) |i| ref.interleaved[i] ^= 0x5A;

    const recovered = try deinterleaveAndCorrect(a, ref.interleaved, ref.version, level);
    defer a.free(recovered);
    try std.testing.expectEqualSlices(u8, ref.data, recovered);
}

test "deinterleaveAndCorrect never silently restores a block beyond capacity" {
    const a = std.testing.allocator;
    const text = "HELLO WORLD"; // v1-M: single block, ec = 10 -> t = 5
    const level: tables.EcLevel = .m;

    const ref = try referenceInterleaved(a, text, level);
    defer a.free(ref.data);
    defer a.free(ref.interleaved);

    // Single block, so the first t+1 codewords are t+1 errors in that one block.
    const s = tables.blockStructure(ref.version, level);
    for (0..s.ec_per_block / 2 + 1) |i| ref.interleaved[i] ^= 0x33;

    // Beyond capacity: must error, or decode to *something other* than the
    // original — never silently hand back the original data.
    if (deinterleaveAndCorrect(a, ref.interleaved, ref.version, level)) |recovered| {
        defer a.free(recovered);
        try std.testing.expect(!std.mem.eql(u8, ref.data, recovered));
    } else |err| {
        try std.testing.expectEqual(error.Uncorrectable, err);
    }
}
